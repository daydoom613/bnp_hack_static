"""Non-critical background work: web hosts enqueue it to SQS, the (Spot-heavy) Worker ASG consumes it.

The queue depth is what the metrics Lambda publishes as FinOps/App queue_length,
and that metric drives the Worker ASG's step scaling.
"""
import hashlib
import json
import logging
import threading
import time
from functools import lru_cache

from . import config, metrics

log = logging.getLogger(__name__)


def burn(ms):
    """Simulated processing: roughly `ms` of CPU, so instance CPU follows the load."""
    if ms <= 0:
        return
    end = time.perf_counter() + ms / 1000
    digest = b"cloudscale"
    while time.perf_counter() < end:
        digest = hashlib.sha256(digest).digest()


@lru_cache(maxsize=1)
def _sqs():
    import boto3

    return boto3.client("sqs", region_name=config.AWS_REGION)


def enqueue(job):
    """Send a job, or do the work inline when there is no queue (local runs). Returns the message id."""
    if not config.QUEUE_URL:
        burn(config.JOB_WORK_MS)
        return None
    response = _sqs().send_message(QueueUrl=config.QUEUE_URL, MessageBody=json.dumps(job))
    metrics.JOBS_ENQUEUED.inc()
    return response["MessageId"]


class Consumer:
    """Long-polls the queue until stop() is called, then finishes the batch in hand.

    Unfinished messages simply become visible again after the visibility timeout,
    so a drained or terminated worker never loses a job.
    """

    def __init__(self, threads=None):
        self._stop = threading.Event()
        self._threads = [threading.Thread(target=self._run, name=f"consumer-{i}", daemon=True)
                         for i in range(threads or config.CONSUMER_THREADS)]

    def start(self):
        for thread in self._threads:
            thread.start()
        log.info("consuming %s with %d threads", config.QUEUE_URL, len(self._threads))

    def stop(self, timeout=60):
        self._stop.set()
        for thread in self._threads:
            thread.join(timeout)
        log.info("consumer stopped")

    def _run(self):
        sqs = _sqs()
        while not self._stop.is_set():
            try:
                batch = sqs.receive_message(
                    QueueUrl=config.QUEUE_URL, MaxNumberOfMessages=10, WaitTimeSeconds=10,
                ).get("Messages", [])
                done = []
                for message in batch:
                    burn(config.JOB_WORK_MS)
                    metrics.JOBS_PROCESSED.inc()
                    done.append({"Id": message["MessageId"], "ReceiptHandle": message["ReceiptHandle"]})
                if done:
                    sqs.delete_message_batch(QueueUrl=config.QUEUE_URL, Entries=done)
            except Exception as exc:
                log.warning("consumer error: %s", exc)
                self._stop.wait(5)

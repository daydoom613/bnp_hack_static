"""Drain a worker before it disappears, then let the ASG finish terminating it.

Triggered by EventBridge on:
  * "EC2 Instance-terminate Lifecycle Action" for the Worker ASG (the lifecycle hook):
    Spot interruption, scale-in, rebalance or instance refresh.
  * "EC2 Spot Instance Interruption Warning" (2-minute notice), as an early start.

Drain = deregister from the ALB target groups (in-flight requests finish during the
deregistration delay) + `docker stop` through SSM, which sends SIGTERM: the app stops
polling SQS and finishes the jobs in hand. Unfinished jobs return to the queue.
Every step is logged as one JSON line, which is the evidence for the chaos test.
"""
import json
import logging
import os
import time

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

WORKER_ASG = os.environ["WORKER_ASG"]
TARGET_GROUP_ARNS = [arn for arn in os.environ.get("TARGET_GROUP_ARNS", "").split(",") if arn]
STOP_TIMEOUT = int(os.environ.get("STOP_TIMEOUT", "60"))

elbv2 = boto3.client("elbv2")
ssm = boto3.client("ssm")
ec2 = boto3.client("ec2")
autoscaling = boto3.client("autoscaling")


def emit(step, **fields):
    log.info(json.dumps({"step": step, **fields}))


def in_worker_asg(instance_id):
    reservations = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
    for reservation in reservations:
        for inst in reservation["Instances"]:
            tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
            return tags.get("aws:autoscaling:groupName") == WORKER_ASG
    return False


def deregister(instance_id):
    for arn in TARGET_GROUP_ARNS:
        try:
            elbv2.deregister_targets(TargetGroupArn=arn, Targets=[{"Id": instance_id}])
            emit("deregistered", instance_id=instance_id, target_group=arn.split(":")[-1])
        except Exception as exc:  # not registered, or already gone
            emit("deregister_skipped", instance_id=instance_id, error=str(exc))


def stop_app(instance_id, deadline):
    """SIGTERM the container and wait (bounded by the Lambda's remaining time)."""
    try:
        command = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Comment="finops-cloudscale drain",
            TimeoutSeconds=max(30, STOP_TIMEOUT + 30),
            Parameters={"commands": [f"docker stop --time {STOP_TIMEOUT} app || true", "docker ps -a --filter name=app"]},
        )["Command"]["CommandId"]
    except Exception as exc:
        emit("stop_failed", instance_id=instance_id, error=str(exc))
        return
    emit("stop_sent", instance_id=instance_id, command_id=command)

    status = "Pending"
    while time.time() < deadline:
        time.sleep(5)
        try:
            status = ssm.get_command_invocation(CommandId=command, InstanceId=instance_id)["Status"]
        except ssm.exceptions.InvocationDoesNotExist:
            continue
        if status in ("Success", "Failed", "Cancelled", "TimedOut"):
            break
    emit("stop_finished", instance_id=instance_id, status=status)


def handler(event, context):
    detail = event.get("detail", {})
    kind = event.get("detail-type", "")
    # Leave 15 s to complete the lifecycle action.
    deadline = time.time() + context.get_remaining_time_in_millis() / 1000 - 15

    if kind == "EC2 Spot Instance Interruption Warning":
        instance_id = detail["instance-id"]
        if not in_worker_asg(instance_id):
            return {"ignored": instance_id}
        emit("spot_interruption_warning", instance_id=instance_id, action=detail.get("instance-action"))
        deregister(instance_id)
        stop_app(instance_id, deadline)
        return {"drained": instance_id}

    if kind == "EC2 Instance-terminate Lifecycle Action":
        instance_id = detail["EC2InstanceId"]
        started = time.time()
        emit("lifecycle_terminating", instance_id=instance_id, asg=detail["AutoScalingGroupName"],
             cause=detail.get("Origin", "") + "->" + detail.get("Destination", ""))
        deregister(instance_id)
        stop_app(instance_id, deadline)
        autoscaling.complete_lifecycle_action(
            AutoScalingGroupName=detail["AutoScalingGroupName"],
            LifecycleHookName=detail["LifecycleHookName"],
            LifecycleActionToken=detail["LifecycleActionToken"],
            InstanceId=instance_id,
            LifecycleActionResult="CONTINUE",
        )
        emit("lifecycle_completed", instance_id=instance_id, drain_seconds=round(time.time() - started, 1))
        return {"drained": instance_id}

    emit("ignored_event", detail_type=kind)
    return {"ignored": kind}

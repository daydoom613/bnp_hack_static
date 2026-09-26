# Non-critical background jobs: web hosts produce, the Spot-heavy Worker ASG consumes.
# Its depth is published as FinOps/App queue_length, which scales the workers.

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-jobs-dlq"
  message_retention_seconds = 345600 # 4 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${var.name}-jobs"
  visibility_timeout_seconds = var.visibility_timeout
  message_retention_seconds  = var.retention_seconds
  receive_wait_time_seconds  = 10 # long polling: fewer (billed) empty receives
  sqs_managed_sse_enabled    = true

  # A job that keeps failing (or keeps losing its worker) is parked, not retried forever.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
}

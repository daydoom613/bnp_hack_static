output "queue_url" {
  value = aws_sqs_queue.jobs.url
}

output "queue_arn" {
  value = aws_sqs_queue.jobs.arn
}

output "queue_name" {
  value = aws_sqs_queue.jobs.name
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

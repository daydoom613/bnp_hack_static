output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "artifacts_bucket_arn" {
  value = aws_s3_bucket.artifacts.arn
}

# Read from the policy resource so the ALB waits for the policy before
# enabling access logs (AWS test-writes to the bucket when logging is enabled).
output "alb_logs_bucket" {
  value = aws_s3_bucket_policy.alb_logs.bucket
}

output "alb_log_prefix" {
  value = var.alb_log_prefix
}

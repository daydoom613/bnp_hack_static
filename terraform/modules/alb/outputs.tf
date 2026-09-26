output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "For CloudWatch RequestCount metrics/alarms."
  value       = aws_lb.this.arn_suffix
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "web_target_group_arn" {
  value = aws_lb_target_group.web.arn
}

output "web_target_group_arn_suffix" {
  value = aws_lb_target_group.web.arn_suffix
}

output "worker_target_group_arn" {
  value = aws_lb_target_group.worker.arn
}

output "worker_target_group_arn_suffix" {
  value = aws_lb_target_group.worker.arn_suffix
}

output "serving_listener_arn" {
  value = local.serving_listener_arn
}

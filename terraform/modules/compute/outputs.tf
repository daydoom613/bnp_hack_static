output "asg_name" {
  value = aws_autoscaling_group.this.name
}

output "asg_arn" {
  value = aws_autoscaling_group.this.arn
}

output "launch_template_id" {
  value = aws_launch_template.this.id
}

output "lifecycle_hook_name" {
  value = var.termination_hook_timeout == null ? null : "${var.name}-${var.tier}-drain"
}

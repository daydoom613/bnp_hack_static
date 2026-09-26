# Output names are used by scripts/, chaos/ and deploy.yml; do not rename them.

output "stack_name" {
  description = "Naming prefix; also the Stack dimension of the FinOps/Cost metrics."
  value       = local.name
}

output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "app_url" {
  value = "${var.certificate_arn == null ? "http" : "https"}://${module.alb.alb_dns_name}"
}

output "health_url" {
  value = "${var.certificate_arn == null ? "http" : "https"}://${module.alb.alb_dns_name}${var.health_check_path}"
}

output "web_asg_name" {
  value = module.web.asg_name
}

output "worker_asg_name" {
  value = module.worker.asg_name
}

output "queue_url" {
  value = module.queue.queue_url
}

output "queue_name" {
  value = module.queue.queue_name
}

output "artifacts_bucket" {
  value = module.storage.artifacts_bucket
}

output "alb_logs_bucket" {
  value = module.storage.alb_logs_bucket
}

output "app_log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "db_host" {
  value = module.rds.db_host
}

output "db_name" {
  value = module.rds.db_name
}

output "db_secret_arn" {
  value = module.rds.db_secret_arn
}

output "image" {
  value = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
}

output "budget_parameter" {
  value = module.functions.budget_parameter_name
}

output "metrics_function" {
  value = module.functions.metrics_function_name
}

output "drain_function" {
  value = module.functions.drain_function_name
}

output "fis_spot_template_id" {
  value = module.chaos.spot_interruption_template_id
}

output "latency_document" {
  value = module.chaos.network_latency_document
}

output "alarms" {
  value = merge(module.scaling.alarm_names, { budget_90 = module.functions.budget_alarm_name })
}

output "fleet" {
  description = "What the dynamic stack runs, for the cost comparison."
  value = {
    web    = { instance_type = var.web_instance_type, min = var.web_min_size, max = var.web_max_size, purchase = "on-demand" }
    worker = { instance_type = var.worker_instance_type, min = var.worker_min_size, max = var.worker_max_size, purchase = "${var.worker_on_demand_percentage}% on-demand / ${100 - var.worker_on_demand_percentage}% spot" }
  }
}

output "alb_subnet_cidrs" {
  description = "Comma-separated, for chaos/latency_injection.sh (netem only on the ALB path)."
  value       = join(",", module.network.public_subnet_cidrs)
}

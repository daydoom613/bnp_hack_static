output "spot_interruption_template_id" {
  description = "Empty when enable_fis = false (chaos/spot_interruption.sh then uses a scripted termination)."
  value       = var.enable_fis ? aws_fis_experiment_template.spot_interruption[0].id : ""
}

output "network_latency_document" {
  value = aws_ssm_document.network_latency.name
}

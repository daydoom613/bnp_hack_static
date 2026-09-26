output "budget_parameter_name" {
  value = aws_ssm_parameter.budget_cap.name
}

output "metrics_function_name" {
  value = aws_lambda_function.metrics_publisher.function_name
}

output "drain_function_name" {
  value = aws_lambda_function.spot_drain.function_name
}

output "budget_alarm_name" {
  value = aws_cloudwatch_metric_alarm.budget_90.alarm_name
}

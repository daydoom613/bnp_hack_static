output "alarm_names" {
  value = {
    web_requests_high = aws_cloudwatch_metric_alarm.web_requests_high.alarm_name
    web_requests_low  = aws_cloudwatch_metric_alarm.web_requests_low.alarm_name
    web_cpu_high      = aws_cloudwatch_metric_alarm.web_cpu_high.alarm_name
    queue_high        = aws_cloudwatch_metric_alarm.queue_high.alarm_name
    queue_low         = aws_cloudwatch_metric_alarm.queue_low.alarm_name
  }
}

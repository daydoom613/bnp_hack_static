# Scaling logic (problem statement "Scaling Logic"):
#   Web ASG    : scale OUT on CPU ~50% (target tracking), ALB requests per target (step)
#                and CPU > 70% for two periods (step, the Basic test's wording);
#                scale IN on ALB requests per target staying low (step). Target tracking's
#                own scale-in is off: with request-sized steps it would flap the peak fleet.
#   Worker ASG : step scaling on the custom metric FinOps/App queue_length, which the
#                metrics Lambda publishes every minute (Lambda-driven step scale).

# ---------------------------------------------------------------------------
# Web tier (On-Demand)
# ---------------------------------------------------------------------------
resource "aws_autoscaling_policy" "web_cpu_target" {
  name                   = "${var.name}-web-cpu-target"
  autoscaling_group_name = var.web_asg_name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = var.cpu_target
    disable_scale_in = true
  }
}

resource "aws_autoscaling_policy" "web_requests_step" {
  name                      = "${var.name}-web-requests-step"
  autoscaling_group_name    = var.web_asg_name
  policy_type               = "StepScaling"
  adjustment_type           = "ChangeInCapacity"
  estimated_instance_warmup = var.instance_warmup

  # Breach up to 2x the threshold: +1. Beyond that: +2.
  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = var.requests_per_target_per_minute
  }

  step_adjustment {
    scaling_adjustment          = 2
    metric_interval_lower_bound = var.requests_per_target_per_minute
  }
}

resource "aws_cloudwatch_metric_alarm" "web_requests_high" {
  alarm_name          = "${var.name}-web-requests-high"
  alarm_description   = "ALB requests per web target above ${var.requests_per_target_per_minute}/min: add web capacity"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "RequestCountPerTarget"
  dimensions          = { TargetGroup = var.web_target_group_arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = var.requests_high_minutes
  threshold           = var.requests_per_target_per_minute
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_autoscaling_policy.web_requests_step.arn]
}

# Back down after the lull: fewer than requests_low_per_target_per_minute per instance for
# web_scale_in_minutes removes one instance per minute until the fleet is sized again.
# No requests at all publishes no datapoints, which also counts as low.
resource "aws_autoscaling_policy" "web_requests_in" {
  name                   = "${var.name}-web-requests-in"
  autoscaling_group_name = var.web_asg_name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    scaling_adjustment          = -1
    metric_interval_upper_bound = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "web_requests_low" {
  alarm_name          = "${var.name}-web-requests-low"
  alarm_description   = "ALB requests per web target below ${var.requests_low_per_target_per_minute}/min for ${var.web_scale_in_minutes} min: remove web capacity"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "RequestCountPerTarget"
  dimensions          = { TargetGroup = var.web_target_group_arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = var.web_scale_in_minutes
  threshold           = var.requests_low_per_target_per_minute
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_autoscaling_policy.web_requests_in.arn]
}

resource "aws_autoscaling_policy" "web_cpu_step" {
  name                      = "${var.name}-web-cpu-step"
  autoscaling_group_name    = var.web_asg_name
  policy_type               = "StepScaling"
  adjustment_type           = "ChangeInCapacity"
  estimated_instance_warmup = var.instance_warmup

  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "web_cpu_high" {
  alarm_name          = "${var.name}-web-cpu-high"
  alarm_description   = "Web CPU above ${var.cpu_high}% for two periods: add an instance"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { AutoScalingGroupName = var.web_asg_name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.cpu_high
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_autoscaling_policy.web_cpu_step.arn]
}

# ---------------------------------------------------------------------------
# Worker tier (70% On-Demand / 30% Spot) driven by queue_length
# ---------------------------------------------------------------------------
resource "aws_autoscaling_policy" "worker_queue_out" {
  name                      = "${var.name}-worker-queue-out"
  autoscaling_group_name    = var.worker_asg_name
  policy_type               = "StepScaling"
  adjustment_type           = "ChangeInCapacity"
  estimated_instance_warmup = var.instance_warmup

  # One worker per breach, so a queue_length spike to 120 adds exactly one.
  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_high" {
  alarm_name          = "${var.name}-queue-length-high"
  alarm_description   = "queue_length above ${var.queue_scale_out_threshold}: add a worker (Spot-eligible)"
  namespace           = var.queue_metric_namespace
  metric_name         = "queue_length"
  dimensions          = { QueueName = var.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.queue_scale_out_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_autoscaling_policy.worker_queue_out.arn]
}

resource "aws_autoscaling_policy" "worker_queue_in" {
  name                   = "${var.name}-worker-queue-in"
  autoscaling_group_name = var.worker_asg_name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    scaling_adjustment          = -1
    metric_interval_upper_bound = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_low" {
  alarm_name          = "${var.name}-queue-length-low"
  alarm_description   = "queue_length below ${var.queue_scale_in_threshold} for ${var.queue_scale_in_minutes} min: remove a worker"
  namespace           = var.queue_metric_namespace
  metric_name         = "queue_length"
  dimensions          = { QueueName = var.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = var.queue_scale_in_minutes
  threshold           = var.queue_scale_in_threshold
  comparison_operator = "LessThanThreshold"
  # No data (Lambda not running) must never shrink the fleet.
  treat_missing_data = "notBreaching"
  alarm_actions      = [aws_autoscaling_policy.worker_queue_in.arn]
}

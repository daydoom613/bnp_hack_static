# Two Lambdas:
#   metrics_publisher  every minute: queue_length (drives worker scaling) and the live
#                      FinOps cost metrics (Grafana, budget alarm, cost report)
#   spot_drain         Worker ASG termination lifecycle hook + Spot interruption warning:
#                      deregister, docker stop via SSM, complete the lifecycle action
# Plus the budget_cap parameter the cost metrics read and the >= 90% budget alarm.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  metrics_fn = "${var.name}-metrics-publisher"
  drain_fn   = "${var.name}-spot-drain"
}

# ---------------------------------------------------------------------------
# Budget cap as a parameter: Terraform writes var.budget_cap (from data/budget_cap.txt).
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "budget_cap" {
  name        = "/${var.name}/budget_cap"
  description = "Monthly budget cap from data/budget_cap.txt; read by the cost metrics every minute"
  type        = "String"
  value       = tostring(var.budget_cap)
}

# ---------------------------------------------------------------------------
# Packaging
# ---------------------------------------------------------------------------
data "archive_file" "metrics_publisher" {
  type        = "zip"
  source_file = "${var.lambda_source_dir}/metrics_publisher/handler.py"
  output_path = "${var.build_dir}/metrics_publisher.zip"
}

data "archive_file" "spot_drain" {
  type        = "zip"
  source_file = "${var.lambda_source_dir}/spot_drain/handler.py"
  output_path = "${var.build_dir}/spot_drain.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# metrics_publisher
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "metrics_publisher" {
  name              = "/aws/lambda/${local.metrics_fn}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "metrics_publisher" {
  name               = local.metrics_fn
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "metrics_publisher" {
  statement {
    sid       = "ReadFleet"
    actions   = ["autoscaling:DescribeAutoScalingGroups", "ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "QueueDepth"
    actions   = ["sqs:GetQueueAttributes"]
    resources = [var.queue_arn]
  }

  statement {
    sid       = "BudgetCap"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.budget_cap.arn]
  }

  statement {
    sid       = "PutFinOpsMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.cost_namespace, var.app_namespace]
    }
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.metrics_publisher.arn}:*"]
  }
}

resource "aws_iam_role_policy" "metrics_publisher" {
  name   = local.metrics_fn
  role   = aws_iam_role.metrics_publisher.id
  policy = data.aws_iam_policy_document.metrics_publisher.json
}

resource "aws_lambda_function" "metrics_publisher" {
  function_name    = local.metrics_fn
  description      = "Publishes queue_length and live FinOps cost metrics every minute"
  role             = aws_iam_role.metrics_publisher.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.metrics_publisher.output_path
  source_code_hash = data.archive_file.metrics_publisher.output_base64sha256
  memory_size      = 128
  timeout          = 30

  environment {
    variables = {
      STACK            = var.name
      WEB_ASG          = var.web_asg_name
      WORKER_ASG       = var.worker_asg_name
      QUEUE_URL        = var.queue_url
      QUEUE_NAME       = var.queue_name
      PRICING_JSON     = jsonencode(var.pricing)
      BASELINE_MONTHLY = tostring(var.baseline_monthly_cost)
      BUDGET_PARAMETER = aws_ssm_parameter.budget_cap.name
      HOURS_PER_MONTH  = tostring(var.hours_per_month)
      COST_NAMESPACE   = var.cost_namespace
      APP_NAMESPACE    = var.app_namespace
    }
  }

  depends_on = [aws_cloudwatch_log_group.metrics_publisher, aws_iam_role_policy.metrics_publisher]
}

resource "aws_cloudwatch_event_rule" "every_minute" {
  name                = "${local.metrics_fn}-schedule"
  description         = "Run the FinOps metrics publisher every minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "every_minute" {
  rule = aws_cloudwatch_event_rule.every_minute.name
  arn  = aws_lambda_function.metrics_publisher.arn
}

resource "aws_lambda_permission" "every_minute" {
  statement_id  = "AllowEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.metrics_publisher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_minute.arn
}

# ---------------------------------------------------------------------------
# spot_drain
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "spot_drain" {
  name              = "/aws/lambda/${local.drain_fn}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "spot_drain" {
  name               = local.drain_fn
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "spot_drain" {
  statement {
    sid       = "Deregister"
    actions   = ["elasticloadbalancing:DeregisterTargets"]
    resources = var.target_group_arns
  }

  statement {
    sid     = "StopContainer"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ssm:${local.region}::document/AWS-RunShellScript",
      "arn:aws:ec2:${local.region}:${local.account_id}:instance/*",
    ]
  }

  statement {
    sid       = "ReadCommandAndInstances"
    actions   = ["ssm:GetCommandInvocation", "ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "CompleteLifecycle"
    actions   = ["autoscaling:CompleteLifecycleAction"]
    resources = [var.worker_asg_arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.spot_drain.arn}:*"]
  }
}

resource "aws_iam_role_policy" "spot_drain" {
  name   = local.drain_fn
  role   = aws_iam_role.spot_drain.id
  policy = data.aws_iam_policy_document.spot_drain.json
}

resource "aws_lambda_function" "spot_drain" {
  function_name    = local.drain_fn
  description      = "Drains worker instances on Spot interruption / termination lifecycle hook"
  role             = aws_iam_role.spot_drain.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.spot_drain.output_path
  source_code_hash = data.archive_file.spot_drain.output_base64sha256
  memory_size      = 128
  # Inside the 2-minute Spot notice and the lifecycle hook's heartbeat timeout.
  timeout = 110

  environment {
    variables = {
      WORKER_ASG        = var.worker_asg_name
      TARGET_GROUP_ARNS = join(",", var.target_group_arns)
      STOP_TIMEOUT      = tostring(var.stop_timeout)
    }
  }

  depends_on = [aws_cloudwatch_log_group.spot_drain, aws_iam_role_policy.spot_drain]
}

resource "aws_cloudwatch_event_rule" "worker_terminating" {
  name        = "${local.drain_fn}-lifecycle"
  description = "Worker ASG termination lifecycle hook"
  event_pattern = jsonencode({
    source        = ["aws.autoscaling"]
    "detail-type" = ["EC2 Instance-terminate Lifecycle Action"]
    detail        = { AutoScalingGroupName = [var.worker_asg_name] }
  })
}

resource "aws_cloudwatch_event_target" "worker_terminating" {
  rule = aws_cloudwatch_event_rule.worker_terminating.name
  arn  = aws_lambda_function.spot_drain.arn
}

resource "aws_lambda_permission" "worker_terminating" {
  statement_id  = "AllowLifecycleHookEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.spot_drain.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.worker_terminating.arn
}

resource "aws_cloudwatch_event_rule" "spot_warning" {
  name        = "${local.drain_fn}-spot-warning"
  description = "EC2 Spot interruption 2-minute notice (the function ignores non-worker instances)"
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_warning" {
  rule = aws_cloudwatch_event_rule.spot_warning.name
  arn  = aws_lambda_function.spot_drain.arn
}

resource "aws_lambda_permission" "spot_warning" {
  statement_id  = "AllowSpotWarningEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.spot_drain.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.spot_warning.arn
}

# ---------------------------------------------------------------------------
# Budget alert: projected monthly cost >= 90% of budget_cap (Grafana turns red too)
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "budget_alerts" {
  count = var.alert_email == null ? 0 : 1
  name  = "${var.name}-budget-alerts"
}

resource "aws_sns_topic_subscription" "budget_alerts" {
  count     = var.alert_email == null ? 0 : 1
  topic_arn = aws_sns_topic.budget_alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "budget_90" {
  alarm_name          = "${var.name}-budget-90pct"
  alarm_description   = "Projected monthly cost is at or above 90% of budget_cap"
  namespace           = var.cost_namespace
  metric_name         = "BudgetUsagePercent"
  dimensions          = { Stack = var.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 90
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = aws_sns_topic.budget_alerts[*].arn
  ok_actions          = aws_sns_topic.budget_alerts[*].arn
}

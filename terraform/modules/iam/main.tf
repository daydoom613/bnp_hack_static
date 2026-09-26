data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_instance" {
  name               = "${var.name}-app-instance"
  description        = "API and worker hosts: pull image, read DB secret, use the job queue, ship logs and metrics"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Starts from the least-privilege example in security_baseline.docx.
data "aws_iam_policy_document" "app_instance" {
  statement {
    sid = "RdsAccess"
    # security_baseline lists "rds:Connect"; the real IAM action is rds-db:connect.
    actions = [
      "rds:DescribeDBInstances",
      "rds-db:connect",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [var.ecr_repository_arn]
  }

  statement {
    sid       = "PutAppMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metrics_namespace]
    }
  }

  # No hard-coded credentials: the app fetches the DB password at runtime.
  statement {
    sid = "ReadDbSecret"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.db_secret_arn]
  }

  # Web hosts enqueue non-critical jobs; worker hosts consume them.
  dynamic "statement" {
    for_each = var.queue_access ? [1] : []

    content {
      sid = "JobQueue"
      actions = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes",
      ]
      resources = [var.queue_arn]
    }
  }

  statement {
    sid = "ShipContainerLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.app_log_group_name}",
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.app_log_group_name}:*",
    ]
  }
}

resource "aws_iam_role_policy" "app_instance" {
  name   = "${var.name}-app-instance"
  role   = aws_iam_role.app_instance.id
  policy = data.aws_iam_policy_document.app_instance.json
}

# Shell access through SSM Session Manager, so no SSH keys or port 22.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app_instance" {
  name = "${var.name}-app-instance"
  role = aws_iam_role.app_instance.name
}

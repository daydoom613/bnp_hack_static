locals {
  https_enabled = var.certificate_arn != null
}

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [var.security_group_id]

  drop_invalid_header_fields = true
  enable_deletion_protection = var.enable_deletion_protection
  idle_timeout               = 60

  access_logs {
    bucket  = var.access_logs_bucket
    prefix  = var.access_logs_prefix
    enabled = true
  }
}

# Target-group names are capped at 32 characters.
resource "aws_lb_target_group" "web" {
  name                 = substr("${var.name}-web", 0, 32)
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = var.health_check_interval
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Worker ASG hosts (On-Demand + Spot). They get API traffic only through the
# X-Target-Tier test rule below; their real job is draining the SQS queue.
resource "aws_lb_target_group" "worker" {
  name                 = substr("${var.name}-worker", 0, 32)
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = var.health_check_interval
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https_enabled ? "redirect" : "forward"
    target_group_arn = local.https_enabled ? null : aws_lb_target_group.web.arn

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []

      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

locals {
  serving_listener_arn = local.https_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
}

# Critical traffic (the simulator sets X-Critical from service_priority.xlsx)
# always lands on the On-Demand web tier. The default action already does
# this; the explicit rule keeps it true if the default ever changes.
# ALB header matching is case-insensitive.
resource "aws_lb_listener_rule" "critical_to_web" {
  listener_arn = local.serving_listener_arn
  priority     = 20

  condition {
    http_header {
      http_header_name = "X-Critical"
      values           = ["true"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# Test hook for the Spot guard: send a request to the worker pool on purpose.
# Spot workers must answer 503 to critical payloads; On-Demand workers serve them.
resource "aws_lb_listener_rule" "worker_test_hook" {
  listener_arn = local.serving_listener_arn
  priority     = 10

  condition {
    http_header {
      http_header_name = "X-Target-Tier"
      values           = ["worker"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.worker.arn
  }
}

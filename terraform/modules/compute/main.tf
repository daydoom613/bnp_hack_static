data "aws_default_tags" "this" {}

data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.al2023[0].insecure_value

  # null = a plain On-Demand ASG; a number = mixed On-Demand/Spot at that On-Demand share.
  mixed = var.on_demand_percentage != null

  # ASGs do not inherit provider default_tags, so the mandatory tags are
  # propagated to every instance explicitly.
  instance_tags = merge(data.aws_default_tags.this.tags, {
    Name = "${var.name}-${var.tier}"
    Tier = var.tier
  })
}

resource "aws_launch_template" "this" {
  name_prefix            = "${var.name}-${var.tier}-"
  image_id               = local.ami_id
  instance_type          = var.instance_type
  update_default_version = true
  vpc_security_group_ids = [var.security_group_id]
  user_data              = base64encode(var.user_data)

  iam_instance_profile {
    name = var.instance_profile_name
  }

  # IMDSv2 only. Hop limit 2 lets the app container (Docker bridge network,
  # one extra hop) reach IMDS for its role credentials, instance-life-cycle
  # (Spot guard) and spot/instance-action (drain on interruption notice).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # 1-minute CPU so target tracking reacts in minutes, not in 5-minute steps.
  monitoring {
    enabled = var.detailed_monitoring
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = local.instance_tags
  }

  tags = { Tier = var.tier }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-${var.tier}-asg"
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  vpc_zone_identifier = var.subnet_ids
  target_group_arns   = var.target_group_arns

  health_check_type         = length(var.target_group_arns) > 0 ? "ELB" : "EC2"
  health_check_grace_period = var.health_check_grace_period
  default_instance_warmup   = var.instance_warmup

  # Launch a replacement as soon as EC2 flags a Spot instance at elevated risk.
  capacity_rebalance = local.mixed ? var.capacity_rebalance : false

  dynamic "launch_template" {
    for_each = local.mixed ? [] : [1]

    content {
      id      = aws_launch_template.this.id
      version = aws_launch_template.this.latest_version
    }
  }

  dynamic "mixed_instances_policy" {
    for_each = local.mixed ? [1] : []

    content {
      instances_distribution {
        on_demand_base_capacity                  = 0
        on_demand_percentage_above_base_capacity = var.on_demand_percentage
        spot_allocation_strategy                 = var.spot_allocation_strategy
      }

      launch_template {
        launch_template_specification {
          launch_template_id = aws_launch_template.this.id
          version            = aws_launch_template.this.latest_version
        }

        dynamic "override" {
          for_each = length(var.instance_type_overrides) > 0 ? var.instance_type_overrides : [var.instance_type]

          content {
            instance_type = override.value
          }
        }
      }
    }
  }

  # Created with the group, so the very first instances are already covered.
  # EventBridge receives the lifecycle action; the drain Lambda completes it.
  dynamic "initial_lifecycle_hook" {
    for_each = var.termination_hook_timeout == null ? [] : [1]

    content {
      name                 = "${var.name}-${var.tier}-drain"
      lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
      heartbeat_timeout    = var.termination_hook_timeout
      default_result       = "CONTINUE"
    }
  }

  # A new image_tag or AMI creates a new launch-template version, and the ASG
  # then replaces instances a few at a time instead of all at once.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = var.refresh_min_healthy_percentage
      instance_warmup        = var.instance_warmup
    }
  }

  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
    "GroupInServiceCapacity",
  ]

  dynamic "tag" {
    for_each = local.instance_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # Scaling policies own desired_capacity after the first apply; without this
  # every apply would reset the fleet to its starting size.
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

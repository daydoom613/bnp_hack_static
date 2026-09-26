

data "aws_iam_policy_document" "fis_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fis" {
  count = var.enable_fis ? 1 : 0

  name               = "${var.name}-fis"
  description        = "AWS FIS experiments for the chaos tests"
  assume_role_policy = data.aws_iam_policy_document.fis_trust.json
}

data "aws_iam_policy_document" "fis" {
  statement {
    sid       = "InterruptSpot"
    actions   = ["ec2:SendSpotInstanceInterruptions"]
    resources = ["arn:aws:ec2:*:*:instance/*"]
  }

  statement {
    sid       = "DescribeTargets"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fis" {
  count = var.enable_fis ? 1 : 0

  name   = "${var.name}-fis"
  role   = aws_iam_role.fis[0].id
  policy = data.aws_iam_policy_document.fis.json
}

resource "aws_fis_experiment_template" "spot_interruption" {
  count = var.enable_fis ? 1 : 0

  description = "Interrupt one running Spot worker (2-minute notice) while jobs are running"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "interrupt-one-spot-worker"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    parameter {
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }

    target {
      key   = "SpotInstances"
      value = "spot-workers"
    }
  }

  target {
    name           = "spot-workers"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "COUNT(1)"

    # Name is propagated by the Worker ASG (modules/compute).
    resource_tag {
      key   = "Name"
      value = var.worker_instance_name
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  tags = { Name = "${var.name}-spot-interruption" }
}

# Only packets to TargetCidrs (the ALB's subnets) are delayed/dropped: that is the
# user-facing path. DB and SQS round trips stay untouched, as they would if the
# fault were really "on the ALB". A prio qdisc with 4 bands keeps normal traffic
# in bands 1-3; the u32 filter moves ALB-bound packets into band 4, where netem sits.
resource "aws_ssm_document" "network_latency" {
  name            = "${var.name}-network-latency"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Add latency and packet loss on the ALB path with tc netem, then remove it automatically."
    parameters = {
      DelayMs         = { type = "String", default = "200", allowedPattern = "^[0-9]{1,4}$" }
      LossPercent     = { type = "String", default = "5", allowedPattern = "^[0-9]{1,2}$" }
      DurationSeconds = { type = "String", default = "60", allowedPattern = "^[0-9]{1,4}$" }
      TargetCidrs     = { type = "String", default = "0.0.0.0/0", allowedPattern = "^[0-9./,]+$" }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "netem"
      inputs = {
        timeoutSeconds = "900"
        runCommand = [
          "set -eu",
          "IFACE=$(ip route show default | awk '{print $5; exit}')",
          "command -v tc >/dev/null || dnf install -y -q iproute-tc",
          "tc qdisc del dev \"$IFACE\" root 2>/dev/null || true",
          "systemd-run --on-active={{ DurationSeconds }}s --unit=netem-revert-$(date +%s) /usr/sbin/tc qdisc del dev \"$IFACE\" root",
          "tc qdisc add dev \"$IFACE\" root handle 1: prio bands 4",
          "tc qdisc add dev \"$IFACE\" parent 1:4 handle 40: netem delay {{ DelayMs }}ms loss {{ LossPercent }}%",
          "for cidr in $(echo '{{ TargetCidrs }}' | tr ',' ' '); do tc filter add dev \"$IFACE\" parent 1: protocol ip prio 1 u32 match ip dst \"$cidr\" flowid 1:4; done",
          "echo \"$(date -Is) netem ON  $IFACE delay={{ DelayMs }}ms loss={{ LossPercent }}% to {{ TargetCidrs }} for {{ DurationSeconds }}s\"",
          "sleep {{ DurationSeconds }}",
          "sleep 3",
          "echo \"$(date -Is) netem OFF: $(tc qdisc show dev \"$IFACE\" | head -1)\"",
        ]
      }
    }]
  })
}

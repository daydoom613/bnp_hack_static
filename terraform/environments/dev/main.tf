# DYNAMIC (optimized) stack: the one that is deployed.
#
#   ALB -> Web ASG     t3.small On-Demand, 1..4, CPU ~50% target tracking + RequestCount step scaling
#       -> Worker ASG  t3.micro 70% On-Demand / 30% Spot (capacity-optimized), 1..4,
#                      scaled on queue_length, termination lifecycle hook -> drain Lambda
#   RDS Postgres, SQS job queue, metrics Lambda (queue_length + live cost), FIS + tc chaos.
#
# The static baseline it is compared with lives in ../baseline and is only ever planned.

locals {
  name      = "${var.project}-${var.environment}"
  repo_root = "${path.module}/../../.."

  # Same pricing the OPA budget guard uses (finops/cost_model.py), for the live cost metrics.
  pricing = {
    for row in csvdecode(file("${local.repo_root}/data/pricing_matrix.csv")) :
    trimspace(row.instance_type) => {
      on_demand = tonumber(row.on_demand_price_per_hour)
      reserved  = tonumber(row.reserved_price_per_hour)
      spot      = tonumber(row.spot_price_per_hour)
    } if trimspace(row.region) == var.aws_region
  }

  # The static fleet's monthly cost (terraform/environments/baseline, priced by cost_model.py).
  baseline_monthly_cost = jsondecode(file("${local.repo_root}/data/baseline_cost.json")).TotalMonthlyCost

  user_data = {
    for tier in ["web", "worker"] : tier => replace(templatefile("${local.repo_root}/scripts/user_data.sh", {
      role                = tier
      region              = var.aws_region
      ecr_registry        = split("/", data.aws_ecr_repository.app.repository_url)[0]
      image               = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
      app_port            = var.app_port
      db_host             = module.rds.db_host
      db_name             = module.rds.db_name
      db_secret_arn       = module.rds.db_secret_arn
      queue_url           = module.queue.queue_url
      log_group           = aws_cloudwatch_log_group.app.name
      critical_work_ms    = var.critical_work_ms
      noncritical_work_ms = var.noncritical_work_ms
      job_work_ms         = var.job_work_ms
    }), "\r", "") # a Windows checkout must never ship a CRLF script
  }
}

data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

module "network" {
  source = "../../modules/network"

  name              = local.name
  vpc_cidr          = var.vpc_cidr
  app_port          = var.app_port
  alb_ingress_cidrs = var.alb_ingress_cidrs
}

module "storage" {
  source = "../../modules/storage"

  name                    = local.name
  artifacts_force_destroy = var.artifacts_force_destroy
}

module "alb" {
  source = "../../modules/alb"

  name               = local.name
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  security_group_id  = module.network.alb_security_group_id
  app_port           = var.app_port
  health_check_path  = var.health_check_path
  certificate_arn    = var.certificate_arn
  access_logs_bucket = module.storage.alb_logs_bucket
  access_logs_prefix = module.storage.alb_log_prefix
}

module "rds" {
  source = "../../modules/rds"

  name              = local.name
  db_subnet_ids     = module.network.db_subnet_ids
  security_group_id = module.network.db_security_group_id
  db_name           = var.db_name
  instance_class    = var.db_instance_class
}

module "queue" {
  source = "../../modules/queue"

  name = local.name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${local.name}/app"
  retention_in_days = 14
}

module "iam" {
  source = "../../modules/iam"

  name               = local.name
  ecr_repository_arn = data.aws_ecr_repository.app.arn
  db_secret_arn      = module.rds.db_secret_arn
  app_log_group_name = aws_cloudwatch_log_group.app.name
  queue_access       = true
  queue_arn          = module.queue.queue_arn
}

# ---------------------------------------------------------------------------
# Web tier: On-Demand only (critical traffic lives here)
# ---------------------------------------------------------------------------
module "web" {
  source = "../../modules/compute"

  name                  = local.name
  tier                  = "web"
  instance_type         = var.web_instance_type
  ami_id                = var.ami_id
  subnet_ids            = module.network.app_subnet_ids
  security_group_id     = module.network.app_security_group_id
  instance_profile_name = module.iam.instance_profile_name
  target_group_arns     = [module.alb.web_target_group_arn]
  user_data             = local.user_data["web"]
  detailed_monitoring   = true

  min_size         = var.web_min_size
  max_size         = var.web_max_size
  desired_capacity = var.web_min_size
}

# ---------------------------------------------------------------------------
# Worker tier: 70% On-Demand / 30% Spot, capacity-optimized, drained on termination
# ---------------------------------------------------------------------------
module "worker" {
  source = "../../modules/compute"

  name                     = local.name
  tier                     = "worker"
  instance_type            = var.worker_instance_type
  instance_type_overrides  = var.worker_instance_type_overrides
  on_demand_percentage     = var.worker_on_demand_percentage
  spot_allocation_strategy = "capacity-optimized"
  capacity_rebalance       = true
  termination_hook_timeout = 180
  ami_id                   = var.ami_id
  subnet_ids               = module.network.app_subnet_ids
  security_group_id        = module.network.app_security_group_id
  instance_profile_name    = module.iam.instance_profile_name
  target_group_arns        = [module.alb.worker_target_group_arn]
  user_data                = local.user_data["worker"]
  detailed_monitoring      = true

  min_size         = var.worker_min_size
  max_size         = var.worker_max_size
  desired_capacity = var.worker_min_size
}

module "scaling" {
  source = "../../modules/scaling"

  name                           = local.name
  web_asg_name                   = module.web.asg_name
  worker_asg_name                = module.worker.asg_name
  web_target_group_arn_suffix    = module.alb.web_target_group_arn_suffix
  queue_name                     = module.queue.queue_name
  cpu_target                     = var.cpu_target
  requests_per_target_per_minute = var.requests_per_target_per_minute
  queue_scale_out_threshold      = var.queue_scale_out_threshold
}

module "functions" {
  source = "../../modules/functions"

  name                  = local.name
  lambda_source_dir     = "${local.repo_root}/lambdas"
  build_dir             = "${path.module}/lambda_build"
  web_asg_name          = module.web.asg_name
  worker_asg_name       = module.worker.asg_name
  worker_asg_arn        = module.worker.asg_arn
  target_group_arns     = [module.alb.worker_target_group_arn]
  queue_url             = module.queue.queue_url
  queue_arn             = module.queue.queue_arn
  queue_name            = module.queue.queue_name
  pricing               = local.pricing
  baseline_monthly_cost = local.baseline_monthly_cost
  budget_cap            = var.budget_cap
  alert_email           = var.alert_email
}

module "chaos" {
  source = "../../modules/chaos"

  name                 = local.name
  worker_instance_name = "${local.name}-worker"
  enable_fis           = var.enable_fis
}

# STATIC BASELINE: the naive fleet the dynamic stack is measured against.
#
#   6 x t3.small On-Demand, 24x7, fixed size, behind the same ALB / RDS / network.
#   That is the dynamic stack's peak compute (4 x t3.small web + 4 x t3.micro worker,
#   = 6 t3.small-equivalents at the pricing matrix's rates) provisioned permanently,
#   which is what you run when nothing scales.
#
# It is ONLY EVER PLANNED, never applied: the fleet never changes, so its monthly cost
# is fully determined by the plan (cost_model.py prices it: 6 x 0.0208 x 730 = 91.10).
# That plan also goes through the same OPA budget guard ("OPA passes a baseline plan").
#
#   scripts/plan_and_check.sh baseline      # -> data/baseline_cost.json with UPDATE_BASELINE=1

locals {
  name      = "${var.project}-baseline"
  repo_root = "${path.module}/../../.."
}

data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

module "network" {
  source = "../../modules/network"

  name     = local.name
  vpc_cidr = var.vpc_cidr
}

module "storage" {
  source = "../../modules/storage"

  name = local.name
}

module "alb" {
  source = "../../modules/alb"

  name               = local.name
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  security_group_id  = module.network.alb_security_group_id
  access_logs_bucket = module.storage.alb_logs_bucket
  access_logs_prefix = module.storage.alb_log_prefix
}

module "rds" {
  source = "../../modules/rds"

  name              = local.name
  db_subnet_ids     = module.network.db_subnet_ids
  security_group_id = module.network.db_security_group_id
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
}

module "web" {
  source = "../../modules/compute"

  name                  = local.name
  tier                  = "web"
  instance_type         = var.instance_type
  subnet_ids            = module.network.app_subnet_ids
  security_group_id     = module.network.app_security_group_id
  instance_profile_name = module.iam.instance_profile_name
  target_group_arns     = [module.alb.web_target_group_arn]

  # Fixed: min = max = desired. No scaling, no Spot, no queue.
  min_size         = var.instance_count
  max_size         = var.instance_count
  desired_capacity = var.instance_count

  user_data = replace(templatefile("${local.repo_root}/scripts/user_data.sh", {
    role                = "web"
    region              = var.aws_region
    ecr_registry        = split("/", data.aws_ecr_repository.app.repository_url)[0]
    image               = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
    app_port            = 8080
    db_host             = module.rds.db_host
    db_name             = module.rds.db_name
    db_secret_arn       = module.rds.db_secret_arn
    queue_url           = ""
    log_group           = aws_cloudwatch_log_group.app.name
    critical_work_ms    = 20
    noncritical_work_ms = 5
    job_work_ms         = 40
  }), "\r", "")
}

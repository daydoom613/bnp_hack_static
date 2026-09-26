provider "aws" {
  region = var.aws_region

  # A wrong AWS_PROFILE fails here instead of deploying into another account.
  allowed_account_ids = [var.aws_account_id]

  # The four mandatory tags from security_baseline, on every taggable resource.
  default_tags {
    tags = {
      Owner       = var.owner
      Project     = var.project
      Environment = var.environment
      Cost_Center = var.cost_center
      Stack       = "dynamic"
      ManagedBy   = "terraform"
    }
  }
}

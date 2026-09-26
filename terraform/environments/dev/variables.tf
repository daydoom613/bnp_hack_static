# ---------------------------------------------------------------------------
# Account / tagging
# ---------------------------------------------------------------------------
variable "aws_region" {
  description = "Must match the region in data/pricing_matrix.csv."
  type        = string
  default     = "eu-west-1"
}

variable "aws_account_id" {
  description = "The account this stack may be deployed to. The provider refuses any other."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be the 12-digit AWS account id."
  }
}

variable "project" {
  type    = string
  default = "finops-cloudscale"
}

variable "owner" {
  description = "Owner tag: e-mail of the product owner."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.owner))
    error_message = "owner must be an e-mail address."
  }
}

variable "environment" {
  description = "Environment tag: dev, staging or prod (security_baseline)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "cost_center" {
  description = "Cost_Center tag: numeric charge-back code."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.cost_center))
    error_message = "cost_center must be numeric."
  }
}

# ---------------------------------------------------------------------------
# Budget guard input. Deliberately NO default and NOT in terraform.tfvars:
# the value comes only from data/budget_cap.txt via TF_VAR_budget_cap
# (scripts/plan_and_check.sh and deploy.yml set it). OPA reads it from the plan.
# ---------------------------------------------------------------------------
variable "budget_cap" {
  description = "Monthly budget ceiling from data/budget_cap.txt. Never set it in code."
  type        = number

  validation {
    condition     = var.budget_cap > 0
    error_message = "budget_cap must be a positive number."
  }
}

# ---------------------------------------------------------------------------
# Web tier (On-Demand). OPA also enforces the t3.* whitelist on it.
# ---------------------------------------------------------------------------
variable "web_instance_type" {
  type    = string
  default = "t3.small"
}

variable "web_min_size" {
  type    = number
  default = 1
}

variable "web_max_size" {
  description = "Peak web capacity (problem statement: 1 -> >= 4, and <= 8 at peak)."
  type        = number
  default     = 4
}

# ---------------------------------------------------------------------------
# Worker tier (mixed On-Demand / Spot)
# ---------------------------------------------------------------------------
variable "worker_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "worker_instance_type_overrides" {
  description = "Extra Spot pools for capacity-optimized. Each type must be in data/pricing_matrix.csv."
  type        = list(string)
  default     = []
}

variable "worker_on_demand_percentage" {
  description = "70 = 70% On-Demand / 30% Spot (problem statement)."
  type        = number
  default     = 70
}

variable "worker_min_size" {
  type    = number
  default = 1
}

variable "worker_max_size" {
  description = "At 4 the 70/30 split gives 3 On-Demand + 1 Spot (AWS rounds the On-Demand share up)."
  type        = number
  default     = 4
}

variable "ami_id" {
  description = "Pin an AMI; null = latest Amazon Linux 2023."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Scaling thresholds
# ---------------------------------------------------------------------------
variable "cpu_target" {
  type    = number
  default = 50
}

variable "requests_per_target_per_minute" {
  description = "ALB requests per web instance per minute before step scaling adds one (2400 = 40 RPS): 50 RPS -> 2, 80 -> 3, 150+ -> 4 instances."
  type        = number
  default     = 2400
}

variable "queue_scale_out_threshold" {
  type    = number
  default = 50
}

# ---------------------------------------------------------------------------
# App contract (README.md, "Contract")
# ---------------------------------------------------------------------------
variable "ecr_repository_name" {
  description = "Created by terraform/backend.tf."
  type        = string
  default     = "finops-cloudscale-app"
}

variable "image_tag" {
  description = "Image tag to run. Changing it rolls both tiers through an instance refresh."
  type        = string
}

variable "app_port" {
  type    = number
  default = 8080
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "db_name" {
  type    = string
  default = "finops"
}

variable "critical_work_ms" {
  description = "Simulated CPU per critical request, so web CPU tracks load (150 RPS of critical requests saturates one t3.small)."
  type        = number
  default     = 20
}

variable "noncritical_work_ms" {
  type    = number
  default = 5
}

variable "job_work_ms" {
  description = "Simulated CPU per queued background job on the workers."
  type        = number
  default     = 40
}

# ---------------------------------------------------------------------------
# Network / edge / data / alerts
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "alb_ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "certificate_arn" {
  description = "ACM cert for HTTPS; null = HTTP only."
  type        = string
  default     = null
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "artifacts_force_destroy" {
  description = "Keep false so terraform destroy cannot wipe the evidence bucket."
  type        = bool
  default     = false
}

variable "enable_fis" {
  description = "AWS FIS for the Spot-interruption chaos test. Set false where the account has no FIS access (e.g. AWS free-plan accounts); the test then terminates the Spot worker through Auto Scaling."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Optional e-mail for the 90%-of-budget alarm (you must confirm the SNS subscription)."
  type        = string
  default     = null
}

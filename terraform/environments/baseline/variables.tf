variable "aws_region" {
  description = "Must match the region in data/pricing_matrix.csv."
  type        = string
  default     = "eu-west-1"
}

variable "aws_account_id" {
  type = string

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
  type = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.owner))
    error_message = "owner must be an e-mail address."
  }
}

variable "environment" {
  type    = string
  default = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "cost_center" {
  type = string

  validation {
    condition     = can(regex("^[0-9]+$", var.cost_center))
    error_message = "cost_center must be numeric."
  }
}

# From data/budget_cap.txt via TF_VAR_budget_cap, never in code. OPA reads it from the plan.
variable "budget_cap" {
  type = number

  validation {
    condition     = var.budget_cap > 0
    error_message = "budget_cap must be a positive number."
  }
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "instance_count" {
  description = "Fixed fleet size, sized for peak because nothing scales."
  type        = number
  default     = 6
}

variable "ecr_repository_name" {
  type    = string
  default = "finops-cloudscale-app"
}

variable "image_tag" {
  type    = string
  default = "v1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

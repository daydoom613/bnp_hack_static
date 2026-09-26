variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev."
  type        = string
}

variable "tier" {
  description = "Tier tag (web or worker). OPA applies the t3.* whitelist to web and requires a Spot mix on worker."
  type        = string
  default     = "web"
}

variable "instance_type" {
  description = "Launch-template instance type. Every type used must be priced in data/pricing_matrix.csv."
  type        = string
  default     = "t3.medium"

  validation {
    condition     = contains(["t3.nano", "t3.micro", "t3.small", "t3.medium"], var.instance_type)
    error_message = "instance_type must be one of t3.nano, t3.micro, t3.small, t3.medium."
  }
}

variable "ami_id" {
  description = "Pin an AMI. null = latest Amazon Linux 2023 (a new AMI release then triggers an instance refresh)."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Private app subnets."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "instance_profile_name" {
  type = string
}

variable "user_data" {
  description = "Rendered scripts/user_data.sh."
  type        = string
}

variable "target_group_arns" {
  type    = list(string)
  default = []
}

variable "min_size" {
  type = number
}

variable "max_size" {
  description = "Also what finops/cost_model.py prices: the most the group could ever run."
  type        = number
}

variable "desired_capacity" {
  description = "Starting size only; scaling policies own it afterwards."
  type        = number
}

# ---------------------------------------------------------------------------
# Spot (mixed instances). Leave on_demand_percentage null for an On-Demand-only group.
# ---------------------------------------------------------------------------
variable "on_demand_percentage" {
  description = "On-Demand share above base capacity (70 = 70% On-Demand / 30% Spot). null = no Spot."
  type        = number
  default     = null

  validation {
    condition     = var.on_demand_percentage == null ? true : (var.on_demand_percentage >= 0 && var.on_demand_percentage <= 100)
    error_message = "on_demand_percentage must be between 0 and 100."
  }
}

variable "spot_allocation_strategy" {
  type    = string
  default = "capacity-optimized"
}

variable "instance_type_overrides" {
  description = "Instance types the mixed policy may launch. Empty = just instance_type."
  type        = list(string)
  default     = []
}

variable "capacity_rebalance" {
  description = "Mixed groups only: replace Spot instances proactively on a rebalance recommendation."
  type        = bool
  default     = true
}

variable "termination_hook_timeout" {
  description = "Seconds a terminating instance waits in Terminating:Wait for the drain Lambda. null = no hook."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Health, refresh, monitoring
# ---------------------------------------------------------------------------
variable "health_check_grace_period" {
  description = "Seconds before ELB health counts: Docker install + image pull + app start."
  type        = number
  default     = 300
}

variable "instance_warmup" {
  description = "Seconds after launch before an instance's metrics count for scaling (boot + image pull + app start)."
  type        = number
  default     = 60
}

variable "refresh_min_healthy_percentage" {
  description = "Instance refresh replaces instances gradually, keeping at least this share healthy."
  type        = number
  default     = 75
}

variable "detailed_monitoring" {
  description = "1-minute EC2 metrics (about $2/instance-month). Needed for responsive CPU target tracking."
  type        = bool
  default     = false
}

variable "root_volume_size" {
  type    = number
  default = 20
}

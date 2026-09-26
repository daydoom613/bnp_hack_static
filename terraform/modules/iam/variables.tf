variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev."
  type        = string
}

variable "ecr_repository_arn" {
  description = "Repo the instances may pull the app image from."
  type        = string
}

variable "db_secret_arn" {
  description = "RDS-managed secret the app reads through DB_SECRET_ARN."
  type        = string
}

variable "app_log_group_name" {
  description = "CloudWatch log group the Docker awslogs driver writes to."
  type        = string
}

variable "metrics_namespace" {
  description = "Only namespace the instances may publish custom CloudWatch metrics to (docs/contracts.md)."
  type        = string
  default     = "FinOps/App"
}

variable "queue_access" {
  description = "Grant the hosts access to queue_arn. A plain bool so it is known at plan time."
  type        = bool
  default     = false
}

variable "queue_arn" {
  description = "SQS job queue the hosts produce to and consume from (used when queue_access = true)."
  type        = string
  default     = null
}

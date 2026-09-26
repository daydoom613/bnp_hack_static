variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "app_port" {
  description = "Target group port = the port the API container listens on."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "Must answer 200 without touching the DB (docs/contracts.md)."
  type        = string
  default     = "/health"
}

variable "health_check_interval" {
  description = "Seconds between health checks; 2 healthy checks put a new instance in service."
  type        = number
  default     = 10
}

variable "deregistration_delay" {
  description = "Seconds the ALB keeps sending in-flight requests to a draining target."
  type        = number
  default     = 30
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS. null = HTTP only (an ALB DNS name cannot get a public cert without a domain)."
  type        = string
  default     = null
}

variable "access_logs_bucket" {
  type = string
}

variable "access_logs_prefix" {
  type    = string
  default = "alb"
}

variable "enable_deletion_protection" {
  type    = bool
  default = false
}

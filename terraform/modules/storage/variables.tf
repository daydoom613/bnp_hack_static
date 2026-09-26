variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev."
  type        = string
}

variable "alb_log_prefix" {
  description = "Key prefix the ALB writes access logs under."
  type        = string
  default     = "alb"
}

variable "alb_log_retention_days" {
  type    = number
  default = 30
}

variable "artifacts_force_destroy" {
  description = "The artifacts bucket holds chaos/cost evidence. Keep false so a destroy cannot wipe it; set true only for a full teardown."
  type        = bool
  default     = false
}

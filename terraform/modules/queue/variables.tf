variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev."
  type        = string
}

variable "visibility_timeout" {
  description = "Seconds a received job stays hidden; longer than the slowest job plus a drain."
  type        = number
  default     = 60
}

variable "retention_seconds" {
  type    = number
  default = 86400
}

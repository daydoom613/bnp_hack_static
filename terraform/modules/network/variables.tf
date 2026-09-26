variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to spread subnets over (ALB and RDS subnet groups need at least 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2."
  }
}

variable "app_port" {
  description = "Port the API container listens on (docs/contracts.md)."
  type        = number
  default     = 8080
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "alb_ingress_cidrs" {
  description = "Who may reach the ALB on 80/443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

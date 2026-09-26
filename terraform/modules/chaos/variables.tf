variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev."
  type        = string
}

variable "worker_instance_name" {
  description = "Name tag the Worker ASG gives its instances (FIS target filter)."
  type        = string
}

variable "enable_fis" {
  description = "Create the AWS FIS Spot-interruption template. false where the account cannot use FIS."
  type        = bool
  default     = true
}

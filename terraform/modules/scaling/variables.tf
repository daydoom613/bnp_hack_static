variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev."
  type        = string
}

variable "web_asg_name" {
  type = string
}

variable "worker_asg_name" {
  type = string
}

variable "web_target_group_arn_suffix" {
  description = "Dimension for the ALB RequestCountPerTarget alarm."
  type        = string
}

variable "queue_name" {
  description = "QueueName dimension of FinOps/App queue_length."
  type        = string
}

variable "queue_metric_namespace" {
  type    = string
  default = "FinOps/App"
}

variable "cpu_target" {
  description = "Target-tracking CPU for the web tier (problem statement: ~50%)."
  type        = number
  default     = 50
}

variable "cpu_high" {
  description = "Step-scaling CPU threshold, two 1-minute periods (Basic test: 70%)."
  type        = number
  default     = 70
}

variable "requests_per_target_per_minute" {
  description = "ALB requests per web instance per minute before adding capacity (2400 = 40 RPS each)."
  type        = number
  default     = 2400
}

variable "requests_high_minutes" {
  description = "Minutes above requests_per_target_per_minute before web scale-out (1 = react within a minute)."
  type        = number
  default     = 1
}

variable "requests_low_per_target_per_minute" {
  description = "Web scale-in: ALB requests per instance per minute below this (1200 = 20 RPS) for web_scale_in_minutes."
  type        = number
  default     = 1200
}

variable "web_scale_in_minutes" {
  type    = number
  default = 5
}

variable "queue_scale_out_threshold" {
  description = "Add a worker while queue_length is above this (Advanced test: 50)."
  type        = number
  default     = 50
}

variable "queue_scale_in_threshold" {
  type    = number
  default = 5
}

variable "queue_scale_in_minutes" {
  description = "Minutes the queue must stay low before a worker is removed."
  type        = number
  default     = 5
}

variable "instance_warmup" {
  description = "Seconds before a new instance's metrics count towards further step scaling."
  type        = number
  default     = 60
}

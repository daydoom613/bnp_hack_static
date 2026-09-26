variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev. Also the Stack dimension of the cost metrics."
  type        = string
}

variable "lambda_source_dir" {
  description = "Folder holding metrics_publisher/ and spot_drain/ (the repo's lambdas/)."
  type        = string
}

variable "build_dir" {
  description = "Where the zips are written. CI carries it from the plan job to the apply job."
  type        = string
}

variable "web_asg_name" {
  type = string
}

variable "worker_asg_name" {
  type = string
}

variable "worker_asg_arn" {
  type = string
}

variable "target_group_arns" {
  description = "Target groups a draining worker is removed from."
  type        = list(string)
}

variable "queue_url" {
  type = string
}

variable "queue_arn" {
  type = string
}

variable "queue_name" {
  type = string
}

variable "pricing" {
  description = "instance_type => {on_demand, reserved, spot} hourly rates, from data/pricing_matrix.csv."
  type        = map(object({ on_demand = number, reserved = number, spot = number }))
}

variable "baseline_monthly_cost" {
  description = "Static fleet's monthly cost, from data/baseline_cost.json."
  type        = number
}

variable "budget_cap" {
  description = "From data/budget_cap.txt via TF_VAR_budget_cap."
  type        = number
}

variable "hours_per_month" {
  type    = number
  default = 730
}

variable "cost_namespace" {
  type    = string
  default = "FinOps/Cost"
}

variable "app_namespace" {
  type    = string
  default = "FinOps/App"
}

variable "stop_timeout" {
  description = "Seconds `docker stop` gives the app to finish its jobs when draining."
  type        = number
  default     = 60
}

variable "alert_email" {
  description = "E-mail for the 90% budget alarm (confirm the SNS subscription). null = no e-mail."
  type        = string
  default     = null
}

variable "log_retention_days" {
  type    = number
  default = 14
}

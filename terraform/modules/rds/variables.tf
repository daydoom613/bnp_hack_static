variable "name" {
  description = "Naming prefix, e.g. finops-cloudscale-dev."
  type        = string
}

variable "db_subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "db_name" {
  description = "Initial database name; passed to the app as DB_NAME."
  type        = string
  default     = "finops"
}

variable "master_username" {
  type    = string
  default = "finops_admin"
}

variable "engine_version" {
  description = "Major version only; AWS picks the current minor."
  type        = string
  default     = "16"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_days" {
  type    = number
  default = 1
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  description = "true for the hackathon so destroy is quick; set false for anything long-lived."
  type        = bool
  default     = true
}

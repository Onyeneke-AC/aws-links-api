variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "project" {
  type    = string
  default = "links"
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "image_tag" {
  description = "Git commit SHA of the image in ECR to run. Set by `make up` / CI, never in tfvars."
  type        = string
}

variable "ecr_repository_name" {
  description = "Created by infra/bootstrap; shared by all environments (build once, promote)."
  type        = string
  default     = "links-api"
}

# ---- per-environment sizing (envs/<env>.tfvars) ---------------------------------

variable "vpc_cidr" {
  description = "Different per environment so dev and prod could be peered later without clashing."
  type        = string
}

variable "desired_count" {
  type = number
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_backup_retention_days" {
  type = number
}

variable "log_level" {
  type    = string
  default = "info"
}

variable "log_retention_days" {
  type = number
}

variable "alarm_email" {
  description = "Where SLO alerts go. Not in tfvars (keeps personal emails out of git): `export TF_VAR_alarm_email=you@example.com`, or a CI secret."
  type        = string
  default     = ""
}

variable "name" {
  description = "Prefix for every resource, e.g. \"links-dev\"."
  type        = string
}

# ---- image ------------------------------------------------------------------

variable "ecr_repository_name" {
  description = "ECR repository holding the app image (created by bootstrap)."
  type        = string
}

variable "image_tag" {
  description = "Image tag to run: the git commit SHA. A deploy is `terraform apply -var image_tag=<sha>`."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{7,40}$", var.image_tag))
    error_message = "image_tag must be a git commit SHA (7-40 hex chars), never a moving tag like \"latest\"."
  }
}

# ---- network ------------------------------------------------------------------

variable "subnet_ids" {
  description = "Private subnets for the tasks."
  type        = list(string)
}

variable "security_group_id" {
  description = "App security group (network module)."
  type        = string
}

variable "target_group_arn" {
  description = "ALB target group the tasks register with (edge module)."
  type        = string
}

variable "container_port" {
  type    = number
  default = 3000
}

# ---- sizing -------------------------------------------------------------------

variable "cpu" {
  description = "Task CPU units (256 = 0.25 vCPU, the Fargate minimum)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory in MiB (512 is the minimum for 256 CPU)."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Running tasks. 2+ spreads across AZs and survives losing one task."
  type        = number
  default     = 1
}

# ---- app config -----------------------------------------------------------------

variable "db_host" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type = string
}

variable "db_secret_arn" {
  description = "RDS-managed Secrets Manager secret (JSON keys: username, password)."
  type        = string
}

variable "public_base_url" {
  description = "Public URL of the service (the ALB), used to build short_url. Empty = omit short_url."
  type        = string
  default     = ""
}

variable "log_level" {
  type    = string
  default = "info"
}

variable "log_retention_days" {
  type    = number
  default = 7
}

# ---- deployment safety ------------------------------------------------------------

variable "deployment_alarm_names" {
  description = "CloudWatch alarms that, if they fire during a deployment, make ECS roll it back."
  type        = list(string)
  default     = []
}

# ---- IAM ----------------------------------------------------------------------------

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the execution role (created by infra/bootstrap). Required: CI may only create boundary-capped roles."
  type        = string
}

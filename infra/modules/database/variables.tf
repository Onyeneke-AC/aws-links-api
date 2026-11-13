variable "name" {
  description = "Prefix for every resource, e.g. \"links-dev\"."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets (at least 2 AZs) for the DB subnet group."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group allowing Postgres from the app tasks only (network module)."
  type        = string
}

variable "engine_version" {
  description = "Postgres MAJOR version only. RDS picks the minor and auto-upgrades it; pinning a minor would make Terraform fight those upgrades."
  type        = string
  default     = "18"
}

variable "instance_class" {
  description = "Graviton burstable class; db.t4g.micro is free-tier eligible."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage_gb" {
  description = "Initial gp3 storage (20 GB is the minimum)."
  type        = number
  default     = 20
}

variable "max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling: RDS grows the disk before it fills up. 0 disables autoscaling."
  type        = number
  default     = 50
}

variable "multi_az" {
  description = "Standby replica in a second AZ with automatic failover. Doubles the DB cost."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention (point-in-time restore window). 0 disables backups."
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "Block deletes. false so `make destroy` works; true for a real production DB."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention for the exported Postgres log group."
  type        = number
  default     = 7
}

variable "name" {
  description = "Prefix for every resource, e.g. \"links-dev\"."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC address range. Must not overlap other environments' VPCs (future peering/VPN)."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid CIDR of /20 or larger (we carve /24 subnets out of it)."
  }
}

variable "az_count" {
  description = "Number of Availability Zones. 2 is the minimum for an ALB and an RDS subnet group."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "app_port" {
  description = "Port the app container listens on (ALB -> task traffic)."
  type        = number
  default     = 3000
}

variable "db_port" {
  description = "Postgres port (task -> RDS traffic)."
  type        = number
  default     = 5432
}

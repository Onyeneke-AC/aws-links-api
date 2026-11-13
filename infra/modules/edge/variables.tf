variable "name" {
  description = "Prefix for every resource, e.g. \"links-dev\"."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Public subnets (2+ AZs) for the ALB."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ALB security group (network module)."
  type        = string
}

variable "app_port" {
  type    = number
  default = 3000
}

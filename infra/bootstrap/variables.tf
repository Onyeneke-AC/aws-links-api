variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Name prefix for every resource. IAM policies are scoped to it."
  type        = string
  default     = "links"
}

variable "github_repo" {
  description = "GitHub repository (owner/name) allowed to assume the CI roles via OIDC."
  type        = string
  default     = "Onyeneke-AC/aws-links-api"
}

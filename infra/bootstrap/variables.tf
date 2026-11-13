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
  description = "GitHub repository (owner/name). Used for tags and descriptions."
  type        = string
  default     = "Onyeneke-AC/aws-links-api"
}

# GitHub's OIDC "sub" identifies the repo by name AND immutable numeric ID:
# repo:<owner>@<owner-id>/<repo>@<repo-id>:... If the repo were renamed or
# deleted and someone recreated the same name, the IDs wouldn't match, so
# that repo couldn't assume our roles.
#
# No default on purpose: `make bootstrap` detects it from the git remote. Empty
# = no CI roles, so bootstrapping in another account (e.g. a reviewer's) never
# grants any GitHub repo access to it.
variable "github_oidc_repo" {
  description = "Repo allowed to assume the CI roles, as in GitHub's OIDC sub: <owner>@<owner-id>/<repo>@<repo-id>. Empty = no CI roles."
  type        = string
  default     = ""

  validation {
    condition     = var.github_oidc_repo == "" || can(regex("^[^/@]+@[0-9]+/[^/@]+@[0-9]+$", var.github_oidc_repo))
    error_message = "Expected <owner>@<owner-id>/<repo>@<repo-id>, or empty for no CI roles."
  }
}

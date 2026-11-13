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
# that repo couldn't assume our roles. Find the IDs with:
#   gh api repos/<owner>/<repo> --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"'
variable "github_oidc_repo" {
  description = "The repo as it appears in GitHub's OIDC sub claim: <owner>@<owner-id>/<repo>@<repo-id>."
  type        = string
  default     = "Onyeneke-AC@98026459/aws-links-api@1454915925"

  validation {
    condition     = can(regex("^[^/@]+@[0-9]+/[^/@]+@[0-9]+$", var.github_oidc_repo))
    error_message = "Expected <owner>@<owner-id>/<repo>@<repo-id>."
  }
}

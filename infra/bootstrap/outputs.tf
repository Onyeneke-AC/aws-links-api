output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "state_bucket" {
  description = "S3 bucket holding Terraform state for every stack."
  value       = aws_s3_bucket.state.bucket
}

output "ecr_repository_url" {
  description = "Push images here as <url>:<git sha>."
  value       = aws_ecr_repository.app.repository_url
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

# For the GitHub Actions workflows (stored as repository variables, not secrets:
# a role ARN isn't sensitive; only GitHub's OIDC token can assume it).
output "ci_role_arns" {
  description = "Empty when no GitHub repo was given (no CI roles)."
  value = local.ci_enabled ? {
    plan       = aws_iam_role.plan[0].arn
    ecr_push   = aws_iam_role.ecr_push[0].arn
    apply_dev  = aws_iam_role.apply["dev"].arn
    apply_prod = aws_iam_role.apply["prod"].arn
  } : {}
}

output "ci_trusted_repo" {
  description = "The GitHub repo (OIDC form) the CI roles trust; empty = none."
  value       = var.github_oidc_repo
}

output "workload_boundary_arn" {
  value = aws_iam_policy.workload_boundary.arn
}

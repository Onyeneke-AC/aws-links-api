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

# Lets GitHub Actions exchange its short-lived OIDC token for short-lived AWS
# credentials (sts:AssumeRoleWithWebIdentity). No access keys exist anywhere.
# Which repo/branch/environment may assume which role is decided by each
# role's trust policy (see the CI roles), not here.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint_list: AWS validates GitHub's certificate against its own
  # trusted CA store for this provider, so a pinned thumbprint isn't needed.
}

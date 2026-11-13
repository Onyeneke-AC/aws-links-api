# Permissions boundary for every IAM role the environments create (today: the
# ECS execution role). A boundary is a ceiling: a role can never do more than
# its boundary allows, whatever policies get attached to it later.
#
# Why: the apply roles must be able to create IAM roles. Without a ceiling, a
# compromised pipeline could create itself an admin role (privilege
# escalation). The apply roles may only create roles that carry THIS boundary
# (see ci_roles.tf), so the worst they can create is "pull our image, write
# logs, read the RDS secret".

resource "aws_iam_policy" "workload_boundary" {
  name        = "${var.project}-workload-boundary"
  description = "Ceiling for roles created by the ${var.project} environments (ECS execution role)."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcrPull"
        Effect = "Allow"
        # GetAuthorizationToken has no resource-level permissions.
        Action   = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = "*"
      },
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/ecs/${var.project}-*"
      },
      {
        Sid    = "ReadRdsManagedSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        # RDS names the secrets it manages "rds!db-<id>".
        Resource = "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:rds!*"
      },
    ]
  })
}

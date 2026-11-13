# ECS uses two different IAM roles; mixing them up is a classic mistake.
#
#   Execution role: used by the ECS *agent* BEFORE the app starts: pull the
#                   image, fetch the DB secret, create the log stream.
#   Task role:      used by the *app's own code* to call AWS APIs.
#
# Our app makes no AWS API calls, so there is NO task role at all: the
# container has zero AWS permissions, and a compromised app can't use any.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    # Confused-deputy guard: only ECS acting for THIS account may assume it.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# Least privilege instead of the broad AWS-managed
# AmazonECSTaskExecutionRolePolicy (which allows pulling ANY image and writing
# to ANY log group).
data "aws_iam_policy_document" "execution" {
  statement {
    sid = "EcrAuthToken"
    # "*" required: GetAuthorizationToken has no resource-level permissions
    # (the token is for the registry, not one repository).
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "PullOurImageOnly"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [data.aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "WriteOurLogGroupOnly"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }

  statement {
    sid       = "ReadDbSecretOnly"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
    # No kms:Decrypt needed: the RDS-managed secret uses the AWS-managed
    # aws/secretsmanager key, which Secrets Manager decrypts on our behalf.
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "least-privilege"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

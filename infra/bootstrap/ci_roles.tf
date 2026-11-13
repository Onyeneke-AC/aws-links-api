# Roles that GitHub Actions assumes through OIDC. No AWS keys exist in GitHub:
# each job exchanges a short-lived GitHub token for 1-hour AWS credentials.
#
# Who may assume what is decided by the token's "sub" claim, which GitHub
# sets from where the job runs:
#
#   role                  sub must equal                         used for
#   links-gha-plan        repo:<repo>:pull_request               terraform plan on PRs (read-only)
#   links-gha-ecr-push    repo:<repo>:ref:refs/heads/main        build + push the image on main
#   links-gha-apply-dev   repo:<repo>:environment:dev            terraform apply to dev
#   links-gha-apply-prod  repo:<repo>:environment:prod           terraform apply to prod (behind approval)
#
# <repo> = owner@<owner-id>/name@<repo-id> (see var.github_oidc_repo).
#
# A job that declares `environment:` gets the environment sub instead of the
# branch sub, which is why the apply roles trust environments. The branch is
# then checked twice: GitHub restricts both environments to main (repo
# settings), and the apply roles' trust also requires ref = refs/heads/main.

locals {
  account_id   = data.aws_caller_identity.current.account_id
  oidc_sub_key = "token.actions.githubusercontent.com:sub"
  oidc_aud_key = "token.actions.githubusercontent.com:aud"
  oidc_ref_key = "token.actions.githubusercontent.com:ref"

  # sub = who may assume; ref = which branch, when sub doesn't say (null = any).
  github_trust = {
    plan       = { sub = "repo:${var.github_oidc_repo}:pull_request", ref = null }        # PR refs vary; role is read-only
    ecr-push   = { sub = "repo:${var.github_oidc_repo}:ref:refs/heads/main", ref = null } # branch is in sub
    apply-dev  = { sub = "repo:${var.github_oidc_repo}:environment:dev", ref = "refs/heads/main" }
    apply-prod = { sub = "repo:${var.github_oidc_repo}:environment:prod", ref = "refs/heads/main" }
  }

  environments = toset(["dev", "prod"])
}

data "aws_iam_policy_document" "github_trust" {
  for_each = local.github_trust

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = local.oidc_aud_key
      values   = ["sts.amazonaws.com"]
    }
    # Exact match, never a wildcard like "repo:<repo>:*".
    condition {
      test     = "StringEquals"
      variable = local.oidc_sub_key
      values   = [each.value.sub]
    }
    # Deploys only from main, enforced by AWS as well as by GitHub's
    # environment branch rule (two independent checks).
    dynamic "condition" {
      for_each = each.value.ref == null ? [] : [each.value.ref]
      content {
        test     = "StringEquals"
        variable = local.oidc_ref_key
        values   = [condition.value]
      }
    }
  }
}

# ---- plan: read-only ---------------------------------------------------------------

resource "aws_iam_role" "plan" {
  name               = "${var.project}-gha-plan"
  description        = "GitHub Actions, pull requests: terraform plan (read-only)."
  assume_role_policy = data.aws_iam_policy_document.github_trust["plan"].json
}

# AWS-managed read-only: terraform plan must be able to read every resource
# type it manages. It cannot change anything and doesn't include reading
# secret values (no secretsmanager:GetSecretValue).
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# The one write: Terraform takes a lock (a .tflock object) even for plan.
resource "aws_iam_role_policy" "plan_state_lock" {
  name = "state-lock"
  role = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "StateLockFilesOnly"
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.state.arn}/live/*.tflock"
    }]
  })
}

# ---- ecr-push: build once on main --------------------------------------------------

resource "aws_iam_role" "ecr_push" {
  name               = "${var.project}-gha-ecr-push"
  description        = "GitHub Actions, main branch: push images to ${aws_ecr_repository.app.name}."
  assume_role_policy = data.aws_iam_policy_document.github_trust["ecr-push"].json
}

resource "aws_iam_role_policy" "ecr_push" {
  name = "push-app-image"
  role = aws_iam_role.ecr_push.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RegistryLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken" # no resource-level permissions
        Resource = "*"
      },
      {
        Sid    = "PushToOurRepositoryOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.app.arn
      },
    ]
  })
}

# ---- apply-dev / apply-prod --------------------------------------------------------
# Read: AWS-managed ReadOnlyAccess (terraform refresh reads everything).
# Write: the inline policy below, one per environment, scoped to resources
# named "<project>-<env>-*" wherever the AWS service supports it.

resource "aws_iam_role" "apply" {
  for_each = local.environments

  name               = "${var.project}-gha-apply-${each.key}"
  description        = "GitHub Actions, environment ${each.key}: terraform apply for ${var.project}-${each.key}."
  assume_role_policy = data.aws_iam_policy_document.github_trust["apply-${each.key}"].json
}

resource "aws_iam_role_policy_attachment" "apply_readonly" {
  for_each = local.environments

  role       = aws_iam_role.apply[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "apply" {
  for_each = local.environments

  # ---- Terraform state: own environment only ----
  statement {
    sid       = "OwnStateOnly"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/live/${each.key}/*"]
  }

  # ---- networking ----
  # "*" with a reason: VPC resources get random IDs (vpc-0abc...), not our
  # names, and several of these calls (routes, rule changes, associations)
  # don't support tag conditions. Limited to the network calls Terraform
  # makes; no instances, volumes or snapshots. Next step: tag conditions on
  # the Delete*/Modify* calls that support them.
  statement {
    sid = "VpcNetworking"
    actions = [
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway", "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
      "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:DisassociateAddress",
      "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
      "ec2:ReplaceRouteTableAssociation", "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
      "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints", "ec2:ModifyVpcEndpoint",
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress", "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
      "ec2:CreateTags", "ec2:DeleteTags",
    ]
    resources = ["*"]
  }

  # ---- load balancer ----
  statement {
    sid     = "OwnLoadBalancer"
    actions = ["elasticloadbalancing:*"]
    resources = [
      "arn:aws:elasticloadbalancing:${var.region}:${local.account_id}:loadbalancer/app/${var.project}-${each.key}-*/*",
      "arn:aws:elasticloadbalancing:${var.region}:${local.account_id}:targetgroup/${var.project}-${each.key}-*/*",
      "arn:aws:elasticloadbalancing:${var.region}:${local.account_id}:listener/app/${var.project}-${each.key}-*/*",
      "arn:aws:elasticloadbalancing:${var.region}:${local.account_id}:listener-rule/app/${var.project}-${each.key}-*/*",
    ]
  }

  # ---- ECS ----
  statement {
    sid     = "OwnEcsClusterAndService"
    actions = ["ecs:*"]
    resources = [
      "arn:aws:ecs:${var.region}:${local.account_id}:cluster/${var.project}-${each.key}",
      "arn:aws:ecs:${var.region}:${local.account_id}:service/${var.project}-${each.key}/*",
      "arn:aws:ecs:${var.region}:${local.account_id}:task-definition/${var.project}-${each.key}-*:*",
    ]
  }

  # "*" with a reason: task definition registration has no resource-level
  # permissions (the revision ARN doesn't exist until the call returns).
  statement {
    sid       = "TaskDefinitionRegistration"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition", "ecs:TagResource"]
    resources = ["*"]
  }

  # ---- RDS ----
  statement {
    sid     = "OwnDatabase"
    actions = ["rds:*"]
    resources = [
      "arn:aws:rds:${var.region}:${local.account_id}:db:${var.project}-${each.key}-*",
      "arn:aws:rds:${var.region}:${local.account_id}:subgrp:${var.project}-${each.key}-*",
      "arn:aws:rds:${var.region}:${local.account_id}:pg:${var.project}-${each.key}-*",
      # CreateDBInstance also checks the engine's default option group.
      "arn:aws:rds:${var.region}:${local.account_id}:og:default:*",
    ]
  }

  # RDS creates and rotates the master password secret on the caller's
  # behalf (manage_master_user_password), so the caller needs these on
  # RDS-named secrets. Reading the value is NOT included.
  statement {
    sid = "RdsManagedSecret"
    actions = [
      "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:RotateSecret",
      "secretsmanager:TagResource", "secretsmanager:UntagResource",
    ]
    resources = ["arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:rds!*"]
  }

  # ---- logs, alarms, dashboard, SNS ----
  statement {
    sid = "OwnLogGroups"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
      "logs:TagResource", "logs:UntagResource", "logs:TagLogGroup", "logs:UntagLogGroup",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/ecs/${var.project}-${each.key}-*",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/rds/instance/${var.project}-${each.key}-*",
    ]
  }

  statement {
    sid = "OwnAlarmsAndDashboard"
    actions = [
      "cloudwatch:PutMetricAlarm", "cloudwatch:PutCompositeAlarm", "cloudwatch:DeleteAlarms",
      "cloudwatch:TagResource", "cloudwatch:UntagResource",
      "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards",
    ]
    resources = [
      "arn:aws:cloudwatch:${var.region}:${local.account_id}:alarm:${var.project}-${each.key}-*",
      "arn:aws:cloudwatch::${local.account_id}:dashboard/${var.project}-${each.key}",
    ]
  }

  statement {
    sid = "OwnAlertsTopic"
    actions = [
      "sns:CreateTopic", "sns:DeleteTopic", "sns:SetTopicAttributes",
      "sns:Subscribe", "sns:Unsubscribe", "sns:TagResource", "sns:UntagResource",
    ]
    resources = ["arn:aws:sns:${var.region}:${local.account_id}:${var.project}-${each.key}-*"]
  }

  # ---- IAM: only boundary-capped roles, only with our env's name ----
  statement {
    sid       = "CreateRolesOnlyWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-${each.key}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  statement {
    sid = "ManageOwnRoles"
    actions = [
      "iam:DeleteRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy", "iam:UpdateRoleDescription",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-${each.key}-*"]
  }

  # ECS needs the execution role handed to it; only to ECS tasks.
  statement {
    sid       = "PassOwnRolesToEcsOnly"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-${each.key}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # A fresh account creates these on first use of ECS / ELB / RDS.
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com", "rds.amazonaws.com"]
    }
  }

  # Belt and braces: never remove the ceiling from a role.
  statement {
    sid       = "NeverRemoveBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply" {
  for_each = local.environments

  name   = "apply-${each.key}"
  role   = aws_iam_role.apply[each.key].id
  policy = data.aws_iam_policy_document.apply[each.key].json
}

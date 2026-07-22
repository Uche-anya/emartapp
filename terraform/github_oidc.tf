# Lets GitHub Actions assume an AWS role by proving which repo and branch it's
# running from, via OIDC, instead of holding a long-lived access key. There's
# no secret to leak: the token is minted per run and expires in minutes.

variable "github_repo" {
  description = "owner/repo allowed to assume the deploy role"
  type        = string
  default     = "Uche-anya/emartapp"
}

data "aws_caller_identity" "current" {}

# GitHub's public OIDC endpoint. One per account; thumbprints are no longer
# validated by AWS for this issuer, but the field is still required.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the main branch of this one repo. Without this, any GitHub repo in
    # the world could assume the role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "${var.project_name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json

  tags = {
    Project = var.project_name
  }
}

# The role can do exactly two things: send a command to this one instance, and
# read back the result. Nothing else.
data "aws_iam_policy_document" "deploy_permissions" {
  statement {
    sid       = "SendCommandToInstance"
    actions   = ["ssm:SendCommand"]
    resources = [aws_instance.emartapp_server.arn]
  }

  statement {
    sid       = "SendCommandUsingDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "ReadCommandResult"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }

  # So the workflow can find the instance by tag instead of a hardcoded ID that
  # breaks on replacement. DescribeInstances has no resource-level scoping.
  statement {
    sid       = "FindInstanceByTag"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "${var.project_name}-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.deploy_permissions.json
}

output "github_deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE secret in GitHub"
  value       = aws_iam_role.github_deploy.arn
}

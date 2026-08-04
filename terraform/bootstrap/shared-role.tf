# CI identity for the account-shared stack (terraform/shared — the ECR
# registry: repositories under otel-demo-app/*, single service `app` today).
# The shared apply rides the dev pipeline's infra job, so trust covers the
# subs that job can present: the plain master-ref sub, and environment:dev
# for when the workflow declares `environment: dev`. Deliberately NOT any
# other environment — staging/prod pipelines consume images, they never
# administer the registry.
#
# Scoped tight instead of bounded-admin: this role exists precisely so the
# env roles' boundaries can DENY them shared-state access without breaking
# the shared apply.
data "aws_iam_policy_document" "shared_trust" {
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
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/master",
        "repo:${local.gh_owner}@${local.gh_owner_id}/${local.gh_name}@${local.gh_repo_id}:ref:refs/heads/master",
        "repo:${var.github_repo}:environment:dev",
        "repo:${local.gh_owner}@${local.gh_owner_id}/${local.gh_name}@${local.gh_repo_id}:environment:dev",
      ]
    }
  }
}

resource "aws_iam_role" "ci_shared" {
  name               = "${var.project}-ci-shared"
  assume_role_policy = data.aws_iam_policy_document.shared_trust.json
}

data "aws_iam_policy_document" "shared_stack" {
  # Full administration of THIS PROJECT'S repositories only — the mirror
  # image of the env boundaries' DenySharedEcrAdministration.
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # token action is account-wide by AWS design
  }
  statement {
    actions   = ["ecr:*"]
    resources = ["arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.project}/*"]
  }
  # Its own state, and nothing else's: the S3 backend needs object rw on the
  # shared key (+ its lockfile) and list on the bucket.
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
  statement {
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${var.state_bucket}/${var.project}/shared.tfstate",
      "arn:aws:s3:::${var.state_bucket}/${var.project}/shared.tfstate.tflock",
    ]
  }
}

resource "aws_iam_role_policy" "shared_stack" {
  name   = "shared-stack"
  role   = aws_iam_role.ci_shared.id
  policy = data.aws_iam_policy_document.shared_stack.json
}

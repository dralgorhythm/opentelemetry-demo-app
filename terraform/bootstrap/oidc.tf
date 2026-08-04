# GitHub Actions → AWS auth via OIDC. No stored keys anywhere: a workflow gets a
# short-lived JWT from GitHub, IAM validates it against the trust policy below,
# STS mints temporary creds.
#
# This stack contains nothing but the CI identity, and it applies LOCALLY:
# the credential CI runs on must exist before CI can run — and must never be
# destroyed by CI. Identity changes stay local-apply-only, matching that
# lifecycle.

data "aws_caller_identity" "current" {}

# One OIDC identity provider per account registers GitHub as a trusted issuer.
# No thumbprint_list: AWS validates this issuer against trusted root CAs —
# the certificate-thumbprint ceremony older guides show is obsolete here.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# GitHub is rolling out immutable sub claims: "repo:owner/name:..." becomes
# "repo:owner@ownerid/name@repoid:..." — name-only trust conditions then fail
# with "Not authorized to perform sts:AssumeRoleWithWebIdentity". Every role
# in this stack matches both formats. The ids are PINNED (an id can't be
# resurrected by re-registering a deleted owner/repo name, so pinning beats
# the `@*` wildcard): resolved 2026-08-04 via
#   gh api repos/dralgorhythm/opentelemetry-demo-app --jq '.id'        → 1323191590
#   gh api repos/dralgorhythm/opentelemetry-demo-app --jq '.owner.id'  → 22618012
# On a fork, re-resolve both and update here alongside var.github_repo.
locals {
  gh_owner    = split("/", var.github_repo)[0]
  gh_name     = split("/", var.github_repo)[1]
  gh_owner_id = "22618012"
  gh_repo_id  = "1323191590"
}

# The per-environment APPLY roles live in environments.tf — one role per
# env, each trusting exactly its GitHub Environment's sub (the documented
# gotcha: `environment: <name>` REPLACES the ref sub), each wrapped in a
# per-env permissions boundary that turns AdministratorAccess into
# "admin inside this environment".

# ── Read-only PLAN role (plan-on-PR) ────────────────────────────────────────
# The apply role trusts main only, so PR workflows can't authenticate as it.
# This second role inverts both knobs: broader trust (any ref/PR of THIS repo —
# PR job tokens present sub "repo:owner/repo:pull_request"), narrower power
# (read-only). A hostile PR can look, not touch.

data "aws_iam_policy_document" "github_trust_plan" {
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
        "repo:${var.github_repo}:*",
        "repo:${local.gh_owner}@${local.gh_owner_id}/${local.gh_name}@${local.gh_repo_id}:*",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_plan" {
  # ONE plan role for the whole account (reads aren't the boundary): it
  # plans every env directory, so it carries NO permissions boundary — a
  # boundary's tag wall would blind it to sibling environments.
  name               = "${var.project}-ci-plan"
  assume_role_policy = data.aws_iam_policy_document.github_trust_plan.json
}

# ReadOnlyAccess covers the refresh reads AND s3:GetObject on the state bucket.
# Plans run with -lock=false, so the role never needs an S3 write.
resource "aws_iam_role_policy_attachment" "ci_plan_readonly" {
  role       = aws_iam_role.github_actions_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

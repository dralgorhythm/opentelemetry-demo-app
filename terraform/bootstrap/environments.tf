# Per-environment CI identity: one apply role per environment, each wrapped
# in a PERMISSIONS BOUNDARY that walls it into its own environment. This is
# the single-account approximation of account-per-env — an env's credential
# can hold AdministratorAccess *inside* the boundary and still be unable to
# read a sibling's state, touch a sibling's secrets/buckets/logs, or
# escalate past the boundary itself. What one account can NEVER give
# (SCPs above these roles, quota isolation, native billing separation,
# credential blast-radius isolation) requires the account-per-env swing.
#
# Solo-account mode is the DEFAULT: just dev, nothing else created. Opting
# into staging/prod = re-apply this stack locally with
# -var-file=environments.tfvars (copy environments.tfvars.example).

variable "environments" {
  description = "Environments this account hosts. Key = env name; drives the role, boundary, and budget per env."
  type = map(object({
    budget_usd = optional(number, 25)
    # Also trust the plain main-ref sub: needed by any main-branch job that
    # runs WITHOUT `environment: <env>` (a job with the environment key
    # presents the environment sub INSTEAD of the ref sub). Dev keeps it on
    # so main-branch deploy jobs work whether or not they declare the
    # GitHub Environment; staging/prod should stay environment-gated only.
    trust_main_ref = optional(bool, false)
  }))
  default = {
    dev = { trust_main_ref = true }
  }
}

locals {
  env_names = keys(var.environments)
  # UNIFORM state layout: every environment lives under envs/. Must match
  # the literal backend blocks in terraform/envs/<env>/ when those stacks
  # land. Siblings in the same bucket: otel-demo-app/bootstrap.tfstate
  # (this stack) and otel-demo-app/shared.tfstate (shared ECR stack).
  state_keys = {
    for env in local.env_names :
    env => "${var.project}/envs/${env}.tfstate"
  }
  env_siblings = {
    for env in local.env_names :
    env => [for o in local.env_names : o if o != env]
  }
  boundary_arns = {
    for env in local.env_names :
    env => "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-${env}-boundary"
  }
}

# ── Trust: each env role is assumable ONLY from its GitHub Environment ────
# A job with `environment: <env>` presents sub "repo:owner/name:environment:<env>"
# INSTEAD of the ref sub (the documented gotcha) — so trusting exactly that
# sub means role assumption is possible only after the GitHub environment's
# protection rules (reviewers, branch policy) have passed.
# Both claim formats, as always (immutable owner@id/name@id twins).
data "aws_iam_policy_document" "env_trust" {
  for_each = var.environments

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
      values = concat(
        [
          "repo:${var.github_repo}:environment:${each.key}",
          "repo:${local.gh_owner}@${local.gh_owner_id}/${local.gh_name}@${local.gh_repo_id}:environment:${each.key}",
        ],
        each.value.trust_main_ref ? [
          "repo:${var.github_repo}:ref:refs/heads/main",
          "repo:${local.gh_owner}@${local.gh_owner_id}/${local.gh_name}@${local.gh_repo_id}:ref:refs/heads/main",
        ] : []
      )
    }
  }
}

resource "aws_iam_role" "ci_apply" {
  for_each = var.environments

  name                 = "${var.project}-${each.key}-ci"
  assume_role_policy   = data.aws_iam_policy_document.env_trust[each.key].json
  permissions_boundary = aws_iam_policy.env_boundary[each.key].arn
  tags                 = { Environment = each.key }
}

# Bounded admin: AdministratorAccess is the attached policy — the boundary
# above is what turns "admin" into "admin inside this environment".
resource "aws_iam_role_policy_attachment" "ci_admin" {
  for_each = var.environments

  role       = aws_iam_role.ci_apply[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ── The boundary: Allow-* ceiling minus five deny walls ───────────────────
# 1 tag wall      — anything tagged with a DIFFERENT env is untouchable
#                   (Null guard keeps untagged/tag-blind APIs working);
# 2 state wall    — sibling/bootstrap/shared Terraform state is unreadable;
# 3 identity wall — no CI role, boundary policy, or the OIDC provider can
#                   be touched (including this role itself — the
#                   self-escalation guard) and no user/key escape hatches;
# 4 name belt     — tag-blind creation/administration on sibling-env name
#                   prefixes (Secrets Manager, S3, logs, dashboards)
#                   plus shared-ECR administration (push stays open);
# 5 boundary self-propagation — any role this credential creates must carry
#                   THIS boundary, and boundaries can't be stripped.
resource "aws_iam_policy" "env_boundary" {
  for_each = var.environments

  name = "${var.project}-${each.key}-boundary"
  tags = { Environment = each.key }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "CeilingAdmin"
          Effect   = "Allow"
          Action   = "*"
          Resource = "*"
        },
        {
          Sid      = "DenyWrongEnvTag"
          Effect   = "Deny"
          Action   = "*"
          Resource = "*"
          Condition = {
            StringNotEquals = { "aws:ResourceTag/Environment" = [each.key, "shared"] }
            Null            = { "aws:ResourceTag/Environment" = "false" }
          }
        },
        {
          Sid    = "DenyForeignState"
          Effect = "Deny"
          Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = concat(
            [
              "arn:aws:s3:::${var.state_bucket}/${var.project}/bootstrap.tfstate",
              "arn:aws:s3:::${var.state_bucket}/${var.project}/bootstrap.tfstate.tflock",
              "arn:aws:s3:::${var.state_bucket}/${var.project}/shared.tfstate",
              "arn:aws:s3:::${var.state_bucket}/${var.project}/shared.tfstate.tflock",
            ],
            flatten([for o in local.env_siblings[each.key] : [
              "arn:aws:s3:::${var.state_bucket}/${local.state_keys[o]}",
              "arn:aws:s3:::${var.state_bucket}/${local.state_keys[o]}.tflock",
            ]])
          )
        },
        {
          Sid    = "DenyTouchingCiIdentity"
          Effect = "Deny"
          # MUTATING verbs only, not iam:* — reads must stay open because
          # provider/module plumbing routinely calls iam:GetRole on the
          # CALLER'S OWN role during plan. Reading CI identity is not an
          # escalation path; changing it is.
          Action = [
            "iam:Add*", "iam:Attach*", "iam:Create*", "iam:Delete*",
            "iam:Detach*", "iam:Put*", "iam:Remove*", "iam:Set*",
            "iam:Tag*", "iam:Untag*", "iam:Update*",
            "sts:AssumeRole",
          ]
          Resource = [
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-*-ci*",
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-ci-*",
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-*-boundary",
            aws_iam_openid_connect_provider.github.arn,
          ]
        },
        {
          Sid    = "DenyIdentityEscapes"
          Effect = "Deny"
          # No blanket OIDC-provider denies here: workload stacks may
          # legitimately create their own providers (e.g. cluster IRSA/
          # workload identity issuers). The GITHUB provider stays protected
          # by DenyTouchingCiIdentity's resource-scoped mutating denies; a
          # rogue new provider is not an escape either, because any role
          # trusting it must still carry this boundary
          # (RequireOwnBoundaryOnRoles).
          Action = [
            "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile",
            "iam:DeleteRolePermissionsBoundary",
          ]
          Resource = "*"
        },
        {
          Sid      = "RequireOwnBoundaryOnRoles"
          Effect   = "Deny"
          Action   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
          Resource = "*"
          Condition = {
            StringNotEquals = { "iam:PermissionsBoundary" = local.boundary_arns[each.key] }
          }
        },
        {
          Sid      = "DenyBudgetTampering"
          Effect   = "Deny"
          Action   = "budgets:*"
          Resource = "*"
        },
        {
          Sid    = "DenySharedEcrAdministration"
          Effect = "Deny"
          Action = [
            "ecr:DeleteRepository", "ecr:PutLifecyclePolicy", "ecr:DeleteLifecyclePolicy",
            "ecr:SetRepositoryPolicy", "ecr:DeleteRepositoryPolicy", "ecr:PutImageTagMutability",
          ]
          Resource = "arn:aws:ecr:*:*:repository/${var.project}/*"
        },
      ],
      length(local.env_siblings[each.key]) == 0 ? [] : [
        {
          Sid    = "DenySiblingNamespaces"
          Effect = "Deny"
          # Tag-blind name belt on sibling-env prefixes. Extend the ARN list
          # with compute-platform resources (ECS/EKS cluster names, etc.)
          # when the workload stack picks one.
          Action = ["secretsmanager:*", "s3:*", "logs:*", "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards"]
          Resource = flatten([for o in local.env_siblings[each.key] : [
            "arn:aws:secretsmanager:*:*:secret:${var.project}-${o}/*",
            "arn:aws:s3:::${var.project}-${o}-*",
            "arn:aws:s3:::${var.project}-${o}-*/*",
            "arn:aws:logs:*:*:log-group:/${var.project}-${o}/*",
            "arn:aws:logs:*:*:log-group:${var.project}-${o}-*",
            "arn:aws:cloudwatch::*:dashboard/${var.project}-${o}-*",
          ]])
        },
      ]
    )
  })
}

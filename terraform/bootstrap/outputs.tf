output "account_id" {
  description = "AWS account id (repo variable AWS_ACCOUNT_ID)."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  description = "Deploy region (repo variable AWS_REGION)."
  value       = var.region
}

output "ci_role_arn" {
  description = "role-to-assume for the DEV pipeline (repo variable CI_ROLE_ARN — env-scoped variables override it for staging/prod)."
  value       = try(aws_iam_role.ci_apply["dev"].arn, null)
}

output "ci_role_arns" {
  description = "Per-environment apply-role ARNs — feed each into that GitHub Environment's CI_ROLE_ARN variable."
  value       = { for k, r in aws_iam_role.ci_apply : k => r.arn }
}

output "ci_plan_role_arn" {
  description = "role-to-assume for the read-only plan-on-PR job (repo variable CI_PLAN_ROLE_ARN)."
  value       = aws_iam_role.github_actions_plan.arn
}

output "ci_shared_role_arn" {
  description = "role-to-assume for the account-shared ECR stack apply (repo variable CI_SHARED_ROLE_ARN)."
  value       = aws_iam_role.ci_shared.arn
}

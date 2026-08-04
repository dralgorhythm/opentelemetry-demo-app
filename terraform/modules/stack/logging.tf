# Cluster log shipping: the CloudWatch Observability add-on (eks.tf addons
# map) runs Fluent Bit for container logs and the CloudWatch agent for
# enhanced Container Insights. This file owns the AWS side of it — the
# agents' identity and the log groups, pre-created so retention is 14 days
# (an agent-created group's default is FOREVER) and so the destroy button
# reaps them with the stack.

# One role for everything the add-on runs: fluent-bit and the agent
# DaemonSet share the cloudwatch-agent service account (chart-verified), so
# a single association covers both. Same shared trust doc as every pod role
# (iam.tf). The association itself rides the add-on entry in eks.tf — the
# add-on API creates it BEFORE the agent pods exist, which a hand-written
# aws_eks_pod_identity_association (the otel.tf pattern) cannot guarantee
# against a module-internal add-on.
resource "aws_iam_role" "cloudwatch_agent" {
  name                 = "${local.name}-cloudwatch-agent"
  assume_role_policy   = data.aws_iam_policy_document.pod_trust.json
  permissions_boundary = local.boundary_arn
}

# AWS-managed agent policy — the otel.tf precedent. Includes
# logs:CreateLogGroup, which is exactly why the groups below are
# pre-created: whoever creates a group sets its retention.
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# The four groups the add-on targets (fluent-bit's three outputs + the
# agent's performance EMF). Named from local.name (otel-demo-app-dev in
# dev), not the module output — no cluster dependency, so they materialize
# in the first seconds of an apply, before any agent pod could race us to
# CreateLogGroup. On Auto Mode (Bottlerocket) application/dataplane/
# performance fill; host is journald-fed and stays sparse — pre-created
# anyway so it can never be born retention-less.
resource "aws_cloudwatch_log_group" "container_insights" {
  for_each          = toset(["application", "dataplane", "host", "performance"])
  name              = "/aws/containerinsights/${local.name}/${each.key}"
  retention_in_days = 14
}

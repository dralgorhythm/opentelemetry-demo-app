# Shared IAM building blocks for every pod-scoped role in this stack.
#
# One service principal for every cluster/account — this is the Pod Identity
# simplification over IRSA (whose trust policy embeds a per-cluster OIDC URL).
# The agent is built into Auto Mode; Fargate can't use Pod Identity at all.
# Consumers today: otel.tf (collector role) and logging.tf (cloudwatch-agent
# role); the app's own pod role joins with the ElastiCache PR.
data "aws_iam_policy_document" "pod_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

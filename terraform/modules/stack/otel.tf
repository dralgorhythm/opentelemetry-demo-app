# Tracing backend identity: the ADOT collector (a Deployment in
# deploy/cluster/ — Kubernetes side, applied by the deploy job) ships spans
# to X-Ray. It gets its own Pod Identity, least-privilege: write traces,
# read nothing, touch nothing else.

resource "aws_iam_role" "otel_collector" {
  name = "${local.name}-otel-collector"
  # Same single service principal every pod role uses — the Pod Identity win.
  assume_role_policy   = data.aws_iam_policy_document.pod_trust.json
  permissions_boundary = local.boundary_arn
}

# AWS-managed write-only X-Ray policy: PutTraceSegments/PutTelemetryRecords
# and sampling-rule reads. No X-Ray read access, no other services.
resource "aws_iam_role_policy_attachment" "otel_xray_write" {
  role       = aws_iam_role.otel_collector.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_eks_pod_identity_association" "otel_collector" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"        # the collector is cluster-scoped plumbing, not an app workload
  service_account = "otel-collector" # = the SA in deploy/cluster/otel-collector.yaml
  role_arn        = aws_iam_role.otel_collector.arn
}

# The app's one stateful dependency: ElastiCache Redis, cluster mode
# DISABLED. That's a hard app constraint, not a preference — the client is
# bb8-redis's non-cluster manager (no MOVED/ASK handling), and GET / does an
# INCRBY (a write), so the app must talk to the PRIMARY endpoint. Encryption
# in transit + at rest and an AUTH token are on; the app compiled in rustls
# support for exactly this (rediss:// URLs).

resource "aws_elasticache_subnet_group" "redis" {
  # Cache lives beside the pods in the private subnets — no separate subnet
  # tier; the /19 privates have thousands of spare IPs and a fourth tier
  # would change the VPC's CIDR arithmetic for zero benefit.
  name       = "${local.name}-redis"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis"
  description = "ElastiCache Redis - ingress only from the EKS Auto Mode fleet"
  vpc_id      = module.vpc.vpc_id
  # No egress rules on purpose: ElastiCache initiates nothing.
}

# One ingress rule: 6379 from the cluster primary SG. Auto Mode nodes attach
# the cluster primary security group, and VPC CNI pods share their node's SG,
# so this admits exactly the fleet and nothing else. TLS rides the same port.
resource "aws_vpc_security_group_ingress_rule" "redis_from_cluster" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis (TLS) from EKS Auto Mode nodes/pods"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = module.eks.cluster_primary_security_group_id
}

# Observed live: the SG-referenced rule above did NOT admit app pods — GET /
# hung the full bb8 connect timeout (dropped SYN symptom). Auto Mode manages
# node ENIs itself and their SG attachment doesn't reliably match the cluster
# primary SG (secondary ENIs are a known gap). This CIDR rule is the working
# path: still private-only (the VPC), with TLS + AUTH on top. Tightening back
# to an exact SG reference once the Auto-Mode-attached SG is pinned down is
# recorded in docs/DEFERRED.md.
resource "aws_vpc_security_group_ingress_rule" "redis_from_vpc" {
  security_group_id = aws_security_group.redis.id
  description       = "Redis (TLS) from anywhere in the VPC (Auto Mode ENI SG workaround)"
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
  cidr_ipv4         = var.vpc_cidr
}

# AUTH token: alphanumeric-only by TWO constraints that happen to agree —
# ElastiCache forbids '@', '"', '/' in tokens, and the token is embedded
# unescaped in the rediss:// URL below (the app does no percent-encoding).
# 32 alphanumeric chars ≈ 190 bits. Rotation = `terraform apply
# -replace=random_password.redis_auth`; ROTATE keeps both tokens valid
# during the rollover, then pods pick up the new URL on restart.
resource "random_password" "redis_auth" {
  length  = 32
  special = false
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${local.name}-redis"
  description          = "visit counter for ${local.name}"

  # "ElastiCache Redis" per the assignment; Valkey is the documented cost
  # follow-up (~20% cheaper, drop-in for this app's INCRBY workload).
  engine         = "redis"
  engine_version = var.redis_engine_version
  node_type      = var.redis_node_type
  port           = 6379

  # ONE knob scales the HA posture: 1 node for dev; >1 flips automatic
  # failover + multi-AZ together (both must be false at 1 node).
  num_cache_clusters         = var.redis_num_cache_clusters
  automatic_failover_enabled = var.redis_num_cache_clusters > 1
  multi_az_enabled           = var.redis_num_cache_clusters > 1

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result
  auth_token_update_strategy = "ROTATE"

  # Dev conveniences; prod would flip both (maintenance-window changes,
  # snapshots retained).
  apply_immediately        = true
  snapshot_retention_limit = 0
}

# ── The app's config file, delivered whole ─────────────────────────────────
# The app reads exactly one YAML file (no env-var overrides), and the redis
# URL embeds the AUTH token — so the ENTIRE config.yml is one Secrets
# Manager secret, CSI-mounted as a file. The k8s side stays dumb plumbing:
# no templating, no ConfigMap/Secret merge story. Terraform owns the value
# end-to-end (endpoint + token both live here), so NO ignore_changes —
# unlike a human-owned secret, drift IS the rotation mechanism.
#
# Known trade, documented for the presentation: token and URL are readable
# in this stack's TF state (encrypted bucket, access walled per state key by
# the CI boundaries). The prod answer is a Secrets Manager rotation Lambda.
resource "aws_secretsmanager_secret" "app_config" {
  name = "${local.name}/app/config"
  # Teardown means teardown (same posture as the rest of the stack); the
  # default 30-day recovery window would wedge the next bring-up drill on a
  # name collision.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app_config" {
  secret_id     = aws_secretsmanager_secret.app_config.id
  secret_string = <<-EOT
    redis_url: "rediss://:${random_password.redis_auth.result}@${aws_elasticache_replication_group.redis.primary_endpoint_address}:6379"
    listen_address: "0.0.0.0:8080"
  EOT
}

# ── App pod identity ───────────────────────────────────────────────────────
# Least privilege by resource: the app's only AWS need is reading its own
# config secret (the Secrets Store CSI driver does the actual fetch using
# the pod's identity).
resource "aws_iam_role" "app_pod" {
  name                 = "${local.name}-app-pod"
  assume_role_policy   = data.aws_iam_policy_document.pod_trust.json
  permissions_boundary = local.boundary_arn
}

resource "aws_iam_role_policy" "app_pod_config_read" {
  name = "read-app-config"
  role = aws_iam_role.app_pod.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.app_config.arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "app" {
  cluster_name    = module.eks.cluster_name
  namespace       = "otel-demo" # = deploy/services/app.yaml's namespace
  service_account = "app"       # = the Helm release name (roster convention)
  role_arn        = aws_iam_role.app_pod.arn
}

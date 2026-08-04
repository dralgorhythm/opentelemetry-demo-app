variable "project" {
  type    = string
  default = "otel-demo-app"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "kubernetes_version" {
  type = string
  # EKS standard support spans 1.33-1.36 (2026-07). Control-plane upgrades are
  # ONE minor at a time — reaching a new target from 1.33 would be three
  # sequential applies (1.34, 1.35, 1.36), each its own PR/merge. Auto Mode
  # rolls nodes to match after each hop.
  default = "1.36" # newest in standard support (2026-07)
}

# ARN of the human admin (e.g. arn:aws:iam::<account-id>:user/admin) to grant
# cluster access. Needed because CI applies this Terraform: the creator-admin
# entry goes to the APPLIER — the CI role — so without this your kubectl gets
# Unauthorized. CI injects it via TF_VAR_admin_principal_arn (see ci.yml).
variable "admin_principal_arn" {
  type    = string
  default = "" # empty = no extra entry
}

# Feeds two independent notification paths, set separately in each stack:
# this stack's SNS alarm subscription (alerting.tf) and, set again in
# terraform/bootstrap (its own copy of this variable), the bootstrap
# stack's AWS Budgets notifications (bootstrap/cost.tf).
# Empty by default so a from-zero apply never needs a real address —
# every resource gated on it is count = var.alert_email != "" ? 1 : 0.
variable "alert_email" {
  type    = string
  default = ""
}

# ── Per-environment knobs (the multi-env surface) ──────────────────────────

# Each environment gets a non-overlapping /16 (dev 10.0, staging 10.1,
# prod 10.2) so future peering/TGW never needs renumbering. Subnets are
# DERIVED (vpc.tf): three /19 privates + three /24 publics.
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# Single NAT (cost) stays the default; a real-HA env flips this to false and
# the VPC module creates one per AZ.
variable "single_nat_gateway" {
  type    = bool
  default = true
}

# The env's IAM permissions boundary (terraform/bootstrap environments.tf),
# threaded onto every role this stack creates — required once the env's CI
# role is bounded, because the boundary denies creating UNbounded roles.
# Empty = no boundary (pre-bootstrap-apply, and local-only users).
variable "iam_permissions_boundary_arn" {
  type    = string
  default = ""
}

# How alerting.tf discovers THIS env's ALB (created out-of-band by the
# cluster's ingress controller, so it's never in state). null derives the
# controller's own tag: { "eks:eks-cluster-name" = <cluster name> }. If
# Auto Mode's tagging ever differs, this knob is the no-surgery fix.
variable "alb_discovery_tags" {
  type    = map(string)
  default = null
}

# Alarm thresholds — identical today, but prod tightening is a one-line
# per-env change instead of a module edit.
variable "alb_5xx_threshold" {
  type    = number
  default = 10
}

variable "alb_latency_threshold_seconds" {
  type    = number
  default = 0.5
}

# ELB-generated 5xx (LB-level failures: no healthy targets, timeouts,
# rejected connections) — the worst-outage signal, separate knob from the
# target-origin count above.
variable "alb_elb_5xx_threshold" {
  type    = number
  default = 10
}

# ── ElastiCache alarm thresholds (alerting.tf) ─────────────────────────────
variable "redis_memory_threshold_percent" {
  type    = number
  default = 80
}

variable "redis_engine_cpu_threshold_percent" {
  type    = number
  default = 90
}

# ── ElastiCache Redis knobs (elasticache.tf) ────────────────────────────────
variable "redis_node_type" {
  type    = string
  default = "cache.t4g.micro" # ~$9/mo — plenty for one INCR counter
}

variable "redis_engine_version" {
  type    = string
  default = "7.1"
}

# The single HA knob: 1 = dev (no failover, no multi-AZ); >1 flips
# automatic failover + multi-AZ together in elasticache.tf.
variable "redis_num_cache_clusters" {
  type    = number
  default = 1
}

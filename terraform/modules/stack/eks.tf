# EKS cluster. The module absorbs the IAM + security-group wiring (its real
# value); the cluster resource itself is small. Cost floor: control plane is a
# flat ~$73/mo whether or not anything runs.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # Control-plane logs: api/audit/authenticator are the MODULE DEFAULT, so
  # they were already flowing — declared here so the choice survives review
  # instead of hiding in module defaults. The module owns
  # /aws/eks/<name>/cluster; the real change is retention: module default
  # 90 -> 14, matching the logging.tf groups.
  enabled_log_types                      = ["audit", "api", "authenticator"]
  cloudwatch_log_group_retention_in_days = 14

  # DECISION: API endpoint exposure — public (active) vs private.
  # Public is convenient for a laptop + CI demo. Private endpoint + a VPN/bastion
  # is the hardened answer; the cheap middle is staying public with
  # endpoint_public_access_cidrs pinned to your own ranges.
  endpoint_public_access = true

  # Whoever applies this Terraform gets an admin access entry on the cluster.
  # Since CI owns every apply, "whoever" is the CI ROLE — which is why humans
  # get their own explicit entry below.
  # (Access entries are the API-native replacement for the aws-auth ConfigMap.)
  # PLAN-READING GOTCHA: "whoever" resolves from the CALLER, so every PR plan
  # (rendered by the read-only -ci-plan role) shows this entry + its policy
  # association "must be replaced" (principal_arn -ci -> -ci-plan) plus a KMS
  # key-policy change — a standing phantom +2 add/+1 change/+2 destroy that
  # vanishes at apply, where the -ci role matches state.
  enable_cluster_creator_admin_permissions = true

  # Roles created by this stack carry the env's permissions boundary once
  # the env is bounded (see variables.tf) — the boundary itself denies
  # creating unbounded roles.
  iam_role_permissions_boundary      = local.boundary_arn
  node_iam_role_permissions_boundary = local.boundary_arn

  # Your kubectl access. Without this you can see the cluster in the console
  # but every kubectl call is Unauthorized — the classic access-entry gotcha,
  # guaranteed to hit here because a human never runs apply.
  access_entries = var.admin_principal_arn == "" ? {} : {
    human-admin = {
      principal_arn = var.admin_principal_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # ── DECISION: compute mode ──────────────────────────────────────────────
  # ACTIVE: pure Auto Mode. AWS owns node provisioning, autoscaling
  # (Karpenter), the VPC CNI, EBS CSI, and the AWS Load Balancer Controller,
  # and Ingress→ALB "just works" (EC2 + a per-instance Auto Mode fee).
  # Auto Mode also serves CNI/kube-proxy/DNS/pod-identity to its nodes
  # off-cluster, so none of the classic add-ons appear below — the first
  # non-Auto managed node group would drag all four back in.
  #
  # general-purpose stays enabled as the anchor for the `default` NodeClass —
  # Auto Mode provisions that NodeClass only while a built-in pool is
  # enabled, so dropping it means owning a custom NodeClass, node role, and
  # access entry.
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }

  # Pure Auto Mode: nodes ride the cluster PRIMARY security group, so the
  # module-default node SG (plus its recommended ingress/egress rules and
  # the matching cluster-SG cross-rules) would attach to nothing — skip it.
  create_node_security_group = false

  # ALTERNATIVE — Fargate (serverless pods, no nodes to patch; higher
  # per-pod cost, you install the AWS LB Controller yourself, no Pod
  # Identity — which this stack's workload identities depend on):
  # comment out compute_config above, then:
  # fargate_profiles = {
  #   default = { selectors = [{ namespace = "default" }, { namespace = "kube-system" }] }
  # }
  # ────────────────────────────────────────────────────────────────────────

  # Auto Mode does NOT bundle metrics-server (no metrics API out of the box).
  # An HPA is blind without it — this managed add-on is its data source.
  # Add-on versions are unpinned on purpose: the module defaults to
  # most_recent, so each plan resolves the newest version compatible with the
  # cluster — deliberate freshness at demo scale. Pin addon_version the first
  # time an add-on bump surprises a deploy. (Digest-pinning is for images,
  # where a silent change ships code.)
  addons = {
    metrics-server = {}

    # Secrets Store CSI driver + AWS provider (ASCP), bundled as one AWS-owned
    # add-on. The nested key configures the upstream driver: secret sync
    # (SecretProviderClass secretObjects -> native k8s Secret, for env-var
    # delivery) and rotation polling (mounted FILES update in-place on
    # rotation; env vars don't until restart). The app consumes its config
    # secret through this driver — see elasticache.tf.
    aws-secrets-store-csi-driver-provider = {
      configuration_values = jsonencode({
        secrets-store-csi-driver = {
          syncSecret           = { enabled = true }
          enableSecretRotation = true
          rotationPollInterval = "30s" # drill-friendly; prod default is 2m
        }
      })
    }

    # Log + metrics shipping: Fluent Bit -> the four
    # /aws/containerinsights/<name>/* groups (pre-created in logging.tf),
    # agent -> enhanced Container Insights. PINNED, unlike the others:
    # add-on v5.0.0 flipped Application Signals auto-monitor ON by default —
    # it would auto-instrument every Service-backed workload, double-trace
    # against the OTel->X-Ray pipeline (otel.tf) and bill per request. That
    # IS the surprise the pin exists for. AppSignals is disabled twice: the
    # explicit agent.config REPLACES the add-on default (which includes
    # application_signals — omitting it means the chart forces auto-monitor
    # off), and monitorAllServices=false is the documented opt-out. Bump the
    # pin deliberately, re-checking both keys against
    # `aws eks describe-addon-configuration`.
    amazon-cloudwatch-observability = {
      addon_version = "v6.2.0-eksbuild.1"
      configuration_values = jsonencode({
        agent = {
          config = {
            logs = {
              metrics_collected = {
                kubernetes = { enhanced_container_insights = true }
              }
            }
          }
        }
        containerLogs = { enabled = true } # the default, declared
        manager = {
          applicationSignals = {
            autoMonitor = { monitorAllServices = false }
          }
        }
      })
      # The add-on API owns the association: created with the add-on, before
      # its pods, deleted with it. Namespace is implied (amazon-cloudwatch);
      # fluent-bit shares this service account.
      pod_identity_association = [{
        role_arn        = aws_iam_role.cloudwatch_agent.arn
        service_account = "cloudwatch-agent"
      }]
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
}

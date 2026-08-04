# The whole per-environment workload composition, as ONE module: VPC + EKS
# (Auto Mode) + workload identities + observability. Each directory under
# terraform/envs/ is a thin root that instantiates this once — the env root
# owns the backend and the provider (with default_tags); this module
# deliberately declares neither, so it inherits both.
terraform {
  required_version = ">= 1.10" # 1.10+ gives native S3 state locking (use_lockfile)

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "${var.project}-${var.environment}"
  # Normalized once: empty string in = null out (providers want null, not "").
  boundary_arn = var.iam_permissions_boundary_arn == "" ? null : var.iam_permissions_boundary_arn
}

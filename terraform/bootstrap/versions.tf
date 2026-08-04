# The BOOTSTRAP stack: the CI identity (OIDC provider + CI roles) and the
# account cost guardrails, nothing else. Separate stack, separate state,
# separate lifecycle — because a stack that destroys the credential CI runs
# on decapitates itself mid-destroy. Workload stacks (terraform/shared,
# terraform/envs/*) are applied and destroyed freely from CI; THIS stack is
# applied and destroyed only LOCALLY, only during account bootstrap or a
# full reset. Runbook: docs/bootstrap.md.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  backend "s3" {
    # TFSTATE-BUCKET-TODO is a placeholder: replace every occurrence in the
    # repo (grep -r TFSTATE-BUCKET-TODO) with the real state bucket name
    # BEFORE `terraform init` — docs/bootstrap.md step 1. Must stay
    # identical to var.state_bucket below.
    bucket       = "TFSTATE-BUCKET-TODO"
    key          = "otel-demo-app/bootstrap.tfstate" # sibling of shared.tfstate and envs/<env>.tfstate
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    # Bootstrap resources are ACCOUNT-scoped, not environment-scoped —
    # Environment = "shared" (per-environment resources override with their
    # own env tag). This tag value is load-bearing: every env boundary
    # (environments.tf) allowlists it next to the env's own.
    tags = { Project = var.project, Environment = "shared", ManagedBy = "terraform-bootstrap" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "otel-demo-app"
}

# Scopes the GitHub OIDC trust (the `sub` claim = the security boundary).
# On a fork, override this AND the pinned ids in oidc.tf's locals.
variable "github_repo" {
  type    = string
  default = "dralgorhythm/opentelemetry-demo-app"
}

# The Terraform state bucket (created by hand in docs/bootstrap.md step 1,
# named in every stack's backend block). The env boundaries deny cross-env
# state access by key, so bootstrap needs the bucket name too. Keep this
# default in lockstep with the backend block above.
variable "state_bucket" {
  type    = string
  default = "TFSTATE-BUCKET-TODO"
}

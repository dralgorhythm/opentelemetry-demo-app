# The STAGING environment root — SCAFFOLDING ONLY, never applied. The
# bootstrap environments map is dev-only today (terraform/bootstrap
# environments.tf), so the bounded staging CI role and boundary policy this
# root assumes DO NOT EXIST yet; opting in = re-apply bootstrap with a
# staging entry in -var-file=environments.tfvars, then wire a promote
# workflow at this directory. An unapplied env root costs $0.
#
# See envs/dev/main.tf for the pattern ("directories, not workspaces").
# What differs from dev is exactly what's visible here: the state key, the
# /16, and the permissions boundary threaded unconditionally from the first
# apply (this root can only ever be applied by the bounded staging CI role
# the bootstrap apply creates, so the boundary always exists first).
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  backend "s3" {
    bucket       = "latent-rustinterview-tfstate" # replaced during bootstrap — see docs/bootstrap.md step 1
    key          = "otel-demo-app/envs/staging.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, Environment = var.environment, ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

module "stack" {
  source = "../../modules/stack"

  project             = var.project
  environment         = var.environment
  admin_principal_arn = var.admin_principal_arn
  alert_email         = var.alert_email

  vpc_cidr = "10.1.0.0/16" # non-overlapping with dev (10.0) and prod (10.2)

  iam_permissions_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-${var.environment}-boundary"
}

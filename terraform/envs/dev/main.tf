# The DEV environment root — "directories, not workspaces": each environment
# is a directory with its own literal backend block and its own state, all
# instantiating the same terraform/modules/stack composition. What varies
# per environment is exactly what this file passes in; everything else is
# identical by construction.
terraform {
  required_version = ">= 1.10" # 1.10+ gives native S3 state locking (use_lockfile)

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # DECISION: state backend — S3 (required: CI owns every apply, and local
  # state can't be shared with CI) vs local, valid only pre-bootstrap. The
  # bucket name is yours to set (docs/bootstrap.md step 1 greps the literal
  # into all five backend blocks); native locking since 1.10 means no
  # DynamoDB table.
  #
  # UNIFORM state layout: every environment lives under
  # otel-demo-app/envs/<env>.tfstate, matching the boundary state-wall in
  # terraform/bootstrap/environments.tf. Siblings in the same bucket:
  # otel-demo-app/bootstrap.tfstate and otel-demo-app/shared.tfstate.
  backend "s3" {
    bucket       = "latent-rustinterview-tfstate" # replaced during bootstrap — see docs/bootstrap.md step 1
    key          = "otel-demo-app/envs/dev.tfstate"
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

locals {
  # By convention, not remote state: bootstrap creates
  # <project>-<env>-boundary; the env root derives the ARN from the name
  # (the repo's cross-stack wire is outputs -> gh variables / naming
  # convention, never state coupling).
  boundary_arn = var.enable_permissions_boundary ? "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-${var.environment}-boundary" : ""
}

module "stack" {
  source = "../../modules/stack"

  region              = var.region
  project             = var.project
  environment         = var.environment
  admin_principal_arn = var.admin_principal_arn
  alert_email         = var.alert_email

  vpc_cidr = "10.0.0.0/16" # dev's block; staging/prod take 10.1/10.2

  iam_permissions_boundary_arn = local.boundary_arn
}

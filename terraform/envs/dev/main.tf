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

module "stack" {
  source = "../../modules/stack"

  project             = var.project
  environment         = var.environment
  admin_principal_arn = var.admin_principal_arn
  alert_email         = var.alert_email

  vpc_cidr = "10.0.0.0/16" # dev's block; staging/prod take 10.1/10.2

  # By convention, not remote state: bootstrap creates
  # <project>-<env>-boundary; the env root derives the ARN from the name
  # (the repo's cross-stack wire is outputs -> gh variables / naming
  # convention, never state coupling). Threaded UNCONDITIONALLY, same as
  # staging/prod: this root is only ever applied by the bounded dev CI role
  # the bootstrap apply creates, so the boundary always exists first.
  iam_permissions_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-${var.environment}-boundary"
}

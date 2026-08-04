# The PROD environment root — reachable, but only after opt-in. This root is
# applied by `promote.yml` with environment=prod, which requires (a) a `prod`
# entry in terraform/bootstrap/environments.tfvars, applied locally, so the
# bounded prod CI role + boundary policy exist, and (b) a protected GitHub
# Environment `prod` carrying that role ARN. Without both, promote fails
# closed at role assumption. Until then this root costs $0.
# Runbook: docs/bootstrap.md "Adding an environment".
#
# See envs/dev/main.tf for the pattern ("directories, not workspaces") and
# envs/staging/main.tf for the multi-env notes. Prod today is
# configuration-identical to staging except its /16 and state key: the prod
# POSTURE upgrades (per-AZ NAT via single_nat_gateway=false, tighter alarm
# thresholds, ACM certs) are each one line here when a real audience
# arrives.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  backend "s3" {
    bucket       = "latent-rustinterview-tfstate" # replaced during bootstrap — see docs/bootstrap.md step 1
    key          = "otel-demo-app/envs/prod.tfstate"
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

  vpc_cidr = "10.2.0.0/16" # non-overlapping with dev (10.0) and staging (10.1)

  iam_permissions_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-${var.environment}-boundary"
}

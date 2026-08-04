# Account-scoped resources that OUTLIVE any single environment — today that's
# the container registry: images are built once and every environment pulls
# the same immutable digest, so a teardown drill must never take the images
# (or this state) with it. Separate stack, separate state key; CI applies it
# in the same infra job that applies the environment stack (ci.yml), under
# the scoped otel-demo-app-ci-shared role (terraform/bootstrap/shared-role.tf).
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  backend "s3" {
    bucket       = "TFSTATE-BUCKET-TODO" # replaced during bootstrap — see docs/bootstrap.md step 1
    key          = "otel-demo-app/shared.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    # Environment = "shared": these resources belong to every environment and
    # to none. The per-env CI boundaries (terraform/bootstrap/environments.tf)
    # allowlist this tag value alongside each environment's own.
    tags = { Project = var.project, Environment = "shared", ManagedBy = "terraform" }
  }
}

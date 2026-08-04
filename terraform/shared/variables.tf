variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "otel-demo-app"
}

# The service roster: one ECR repo per entry (ecr.tf for_each). A new
# service = one entry here + one values file under deploy/services/.
variable "services" {
  type    = list(string)
  default = ["app"]
}

# The account-per-env seam: when an environment graduates to its own AWS
# account, list that account id here and ecr.tf's repository policy grants it
# pull. Images keep being built once, in THIS account; other accounts pull.
variable "cross_account_pull_account_ids" {
  type    = list(string)
  default = []
}

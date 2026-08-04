# The root variable surface = exactly what CI injects (TF_VAR_*) plus the
# identity of this environment. Everything else lives on the stack module's
# own inputs with defaults.
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "otel-demo-app"
}

variable "environment" {
  type    = string
  default = "dev"
}

# ARN of the human admin (e.g. arn:aws:iam::<account-id>:user/admin) to grant
# cluster access. Needed because CI applies this Terraform: the creator-admin
# entry goes to the APPLIER — the CI role — so without this your kubectl gets
# Unauthorized. CI injects it via TF_VAR_admin_principal_arn (see ci.yml).
variable "admin_principal_arn" {
  type    = string
  default = ""
}

# The ALB-alarm email (stack module alerting). CI injects TF_VAR_alert_email
# from the ALERT_EMAIL repo variable; empty keeps alerting unsubscribed.
variable "alert_email" {
  type    = string
  default = ""
}

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
  default = "prod"
}

# A future promote workflow injects TF_VAR_admin_principal_arn /
# TF_VAR_alert_email exactly as ci.yml's infra job does for dev.
variable "admin_principal_arn" {
  type    = string
  default = ""
}

variable "alert_email" {
  type    = string
  default = ""
}

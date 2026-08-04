# Account cost guardrail: a flat monthly budget. Anomaly detection is NOT
# terraformed on purpose: AWS auto-creates one dimensional SERVICE monitor
# per account (Default-Services-Monitor) and one is the hard cap — a
# terraformed twin fails with "Limit exceeded on dimensional spend monitor
# creation". The path back, if anomaly EMAILS are ever wanted: an
# aws_ce_anomaly_subscription pointing at the default monitor's ARN.
#
# DECISION: this lives in BOOTSTRAP because it must SURVIVE the destroy
# button — its whole job is watching the account while the workload stacks
# are down ("did a teardown forget something"). Same lifecycle class as the
# CI identity: created once, locally, never destroyed by CI.

# Passed at the local bootstrap apply (docs/bootstrap.md step 2). Empty =
# no budgets created, so from-zero applies stay green either way. Separate
# wire from any workload-stack alert email a repo variable might feed —
# two stacks, two appliers, two independent wires.
variable "alert_email" {
  type    = string
  default = ""
}

variable "monthly_budget_usd" {
  type = number
  # Account-total ceiling; the per-env tag-filtered budgets below carry the
  # fine-grained tripwires (default $25 per env, override via the
  # environments map).
  default = 50
}

# Flat monthly ceiling. Three notifications on purpose: two ACTUAL
# checkpoints to catch a slow burn (50%, 90%) and one FORECASTED
# checkpoint (100%) to catch a fast burn before the bill actually clears
# the line — AWS's forecast uses the current month's trend, so it can fire
# mid-month on a trajectory alone.
# Verify once after the first real apply: a second `terraform plan` must
# report "No changes" — aws_budgets_budget has a known pattern of echoing
# computed time_period values back as perpetual diffs; if that bites, pin
# time_period_start explicitly.
resource "aws_budgets_budget" "monthly" {
  count = var.alert_email != "" ? 1 : 0

  name         = "${var.project}-account-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# Per-environment budgets, filtered by the Environment cost-allocation tag
# every stack's default_tags stamp. ONE-TIME MANUAL PREREQUISITE
# (docs/bootstrap.md step 2): activate the tag —
#   aws ce update-cost-allocation-tags-status \
#     --cost-allocation-tags-status TagKey=Environment,Status=Active
# — and allow ~24h; until then these budgets match nothing (harmlessly $0).
resource "aws_budgets_budget" "env_monthly" {
  for_each = var.alert_email != "" ? var.environments : {}

  name         = "${var.project}-${each.key}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(each.value.budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name = "TagKeyValue"
    # Literal format is user:<TagKey>$<TagValue> — format() sidesteps HCL's
    # "$${" literal-escape trap for a $ directly before an interpolation.
    values = [format("user:Environment$%s", each.key)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

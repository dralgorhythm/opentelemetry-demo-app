# ALB alarms -> SNS -> email, plus a dashboard — all from signals that
# already flow free at this volume.
#
# DECISION: lives in the WORKLOAD stack: these alarms watch an ALB that
# exists only while the stack is up, so they share its lifecycle. The
# mirror-image guardrails that must SURVIVE the destroy button live in
# terraform/bootstrap/cost.tf — lifecycle-matched placement.
# The email lands only when CI passes TF_VAR_alert_email — the ALERT_EMAIL
# repo variable, mapped in ci.yml's plan+infra jobs (CI is this stack's
# only applier).

# ── ALB auto-pin (the multi-env fix for "every ALB aggregates into one
# signal") ────────────────────────────────────────────────────────────────
# The ALB is cluster-created and never in state, so it's DISCOVERED by tag
# at plan time: exactly one match → every query below pins to it with a
# WHERE clause (and the latency alarm upgrades to a real p95); zero or
# ambiguous → the original SCHEMA aggregates, so a from-zero apply stays
# green and a torn-down env never references a dead ALB. Self-healing: the
# data source re-reads each plan, so after every teardown/bring-up cycle
# the pin lands on the next terraform-touching apply. The honest gap: an
# env is account-aggregate between its bring-up and that next apply.
data "aws_lbs" "env" {
  # Auto Mode's built-in controller tags with eks:eks-cluster-name (plus
  # ingress.eks.amazonaws.com/*), NOT the classic AWS LB Controller's
  # elbv2.k8s.aws/cluster — verified live on the template this stack was
  # adapted from; a wrong guess finds 0 and falls back to aggregate.
  tags = coalesce(var.alb_discovery_tags, { "eks:eks-cluster-name" = local.name })
}

locals {
  alb_arn_suffix = length(data.aws_lbs.env.arns) == 1 ? regex("loadbalancer/(.+)$", tolist(data.aws_lbs.env.arns)[0])[0] : ""
  alb_pinned     = local.alb_arn_suffix != ""
  alb_where      = local.alb_pinned ? " WHERE LoadBalancer = '${local.alb_arn_suffix}'" : ""
}

# One home for every query string: the alarms and the dashboard widgets
# below share these definitions — the auto-pin WHERE clause added here
# lands in both.
# Unpinned, SCHEMA(...) matches by namespace+dimension shape — every ALB
# in this account/region aggregates into one signal (the pre-multi-env
# posture, kept as the fallback).
locals {
  q_target_5xx  = "SELECT SUM(HTTPCode_Target_5XX_Count) FROM SCHEMA(\"AWS/ApplicationELB\", LoadBalancer)${local.alb_where}"
  q_elb_5xx     = "SELECT SUM(HTTPCode_ELB_5XX_Count) FROM SCHEMA(\"AWS/ApplicationELB\", LoadBalancer)${local.alb_where}"
  q_avg_latency = "SELECT AVG(TargetResponseTime) FROM SCHEMA(\"AWS/ApplicationELB\", LoadBalancer)${local.alb_where}"
  q_requests    = "SELECT SUM(RequestCount) FROM SCHEMA(\"AWS/ApplicationELB\", LoadBalancer)${local.alb_where}"
  q_healthy_min = "SELECT MIN(HealthyHostCount) FROM SCHEMA(\"AWS/ApplicationELB\", LoadBalancer, TargetGroup)${local.alb_where}"

  # ── Logs Insights queries (request-log analytics) ───────────────────────
  # Two add-on defaults shape every string here: Fluent Bit's kubernetes
  # filter nests merged JSON under log_processed.* (Merge_Log_Key), and it
  # ships NO pod labels (Labels Off) — so the service name is derived from
  # the pod-name prefix, not kubernetes.labels.app.
  # Field mapping is the app's tower-http on_response event ("HTTP request
  # completed" with status_code + latency_ms, src/middleware.rs), nested
  # under fields.* by tracing-subscriber's JSON formatter. HONEST CAVEAT:
  # the app ships human-readable text logs today, so log_processed.* stays
  # empty and these queries return nothing until the JSON formatter lands
  # (deferred) — they're wired now so log shipping and analytics arrive as
  # one story, not two migrations.
  # KNOWN CONSTRAINT: parse '*-*' splits pod_name at the FIRST hyphen, so a
  # hyphenated release name (the roster convention allows them) mis-buckets
  # — pod "some-api-6d5f4c-xyz" reports svc="some". Fine at demo scale;
  # revisit by shipping a real label when Fluent Bit label-shipping returns.
  q_logs_p95    = <<-EOT
    filter log_processed.fields.message = 'HTTP request completed'
    | parse kubernetes.pod_name '*-*' as svc, rest
    | stats count(*) as requests, avg(log_processed.fields.latency_ms) as avg_ms, pct(log_processed.fields.latency_ms, 95) as p95_ms, pct(log_processed.fields.latency_ms, 99) as p99_ms by svc
    | sort p95_ms desc
  EOT
  q_logs_errors = <<-EOT
    fields @timestamp, kubernetes.namespace_name, kubernetes.pod_name, log_processed.fields.status_code, log_processed.fields.latency_ms
    | filter log_processed.fields.message = 'HTTP request completed' and log_processed.fields.status_code >= 500
    | sort @timestamp desc
    | limit 100
  EOT
  q_logs_volume = <<-EOT
    parse kubernetes.pod_name '*-*' as svc, rest
    | stats count(*) as lines, sum(strlen(@message)) as est_bytes by kubernetes.namespace_name, svc
    | sort est_bytes desc
  EOT
  # Widget-only variant: p95 as a time series (by bin) instead of by service.
  q_logs_p95_bin = "filter log_processed.fields.message = 'HTTP request completed' | stats pct(log_processed.fields.latency_ms, 95) as p95_ms by bin(5m)"
}

# The topic exists unconditionally, independent of whether anyone has
# subscribed yet. Slack (AWS Chatbot / Amazon Q Developer in chat apps,
# resource aws_chatbot_slack_channel_configuration) and PagerDuty (an SNS ->
# Events API subscription) both attach to THIS topic later — that's the
# whole reason it's not folded into the count-gated subscription below.
# No topic policy on purpose: same-account CloudWatch alarms may publish to
# a same-account topic under the default policy (a policy only becomes
# necessary cross-account). Verify once on a live stack:
#   aws cloudwatch set-alarm-state --alarm-name <name> --state-value ALARM --state-reason test
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

# Email subscription, created only when an address is configured. The one
# manual step SNS can't automate: the subscriber must click the
# confirmation email AWS sends before the subscription goes "Confirmed" —
# no Terraform resource can complete that click on your behalf.
resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Both alarms below use Metrics Insights SELECT expressions instead of a
# dimension-pinned metric. Reason: the ALB is cluster-created from the
# Ingress (Auto Mode's load balancing capability provisions it) and is NOT
# a Terraform resource — its ARN/name never lands in this state, so an
# alarm pinned to a specific LoadBalancer dimension would have nothing to
# reference on a from-zero apply and would break it. SCHEMA(...) queries
# match by namespace + dimension shape instead, so the alarm exists before
# the first ALB ever does.
resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  alarm_name          = "${local.name}-alb-target-5xx"
  alarm_description   = local.alb_pinned ? "Target-origin 5xx responses on ${local.alb_arn_suffix} (auto-pinned by cluster tag)." : "Target-origin 5xx responses summed across every ALB in the account (no ALB discovered to pin — see the auto-pin header)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.alb_5xx_threshold
  # No ALB yet, or no traffic yet, means no data points — that must read as
  # GREEN (healthy), not alarming, or every from-zero apply starts red.
  treat_missing_data = "notBreaching"

  metric_query {
    id          = "q1"
    period      = 300
    return_data = true
    expression  = local.q_target_5xx
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_target_latency" {
  alarm_name = "${local.name}-alb-target-latency"
  # Two forms, switched by the auto-pin: Metrics Insights SELECT supports
  # AVG/SUM/MIN/MAX/COUNT only — no percentiles — so the UNPINNED fallback
  # watches AVG (catches sustained regressions, absorbs p95 spikes at low
  # volume). The moment the env's ALB is discoverable, the alarm flips to
  # the dimension-pinned metric form and the statistic upgrades to a real
  # p95 (the limitation dies with the pin).
  alarm_description   = local.alb_pinned ? "p95 target response time on ${local.alb_arn_suffix} (auto-pinned by cluster tag)." : "Average target response time across every ALB in the account (AVG only until an ALB is discovered to pin — MI has no percentiles)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.alb_latency_threshold_seconds
  treat_missing_data  = "notBreaching"

  # Pinned form: plain metric + extended statistic.
  metric_name        = local.alb_pinned ? "TargetResponseTime" : null
  namespace          = local.alb_pinned ? "AWS/ApplicationELB" : null
  period             = local.alb_pinned ? 300 : null
  extended_statistic = local.alb_pinned ? "p95" : null
  dimensions         = local.alb_pinned ? { LoadBalancer = local.alb_arn_suffix } : null

  # Unpinned form: the Metrics Insights aggregate.
  dynamic "metric_query" {
    for_each = local.alb_pinned ? [] : [1]
    content {
      id          = "q1"
      period      = 300
      return_data = true
      expression  = local.q_avg_latency
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ELB-generated 5xx: failures the TARGETS never see — zero healthy targets,
# connection timeouts, rejected connections. A total outage produces ONLY
# this count (target 5xx needs a target to answer), so it gets its own
# alarm rather than riding the target-5xx one. Same discovery story: the
# shared q_elb_5xx local carries the auto-pin WHERE clause.
resource "aws_cloudwatch_metric_alarm" "alb_elb_5xx" {
  alarm_name          = "${local.name}-alb-elb-5xx"
  alarm_description   = local.alb_pinned ? "ELB-generated 5xx responses on ${local.alb_arn_suffix} (auto-pinned by cluster tag) — LB-level failures, e.g. no healthy targets." : "ELB-generated 5xx responses summed across every ALB in the account (no ALB discovered to pin — see the auto-pin header)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.alb_elb_5xx_threshold
  # Same from-zero posture as the target-5xx alarm: no ALB or no traffic
  # means no data points, which must read GREEN.
  treat_missing_data = "notBreaching"

  metric_query {
    id          = "q1"
    period      = 300
    return_data = true
    expression  = local.q_elb_5xx
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ── ElastiCache alarms ─────────────────────────────────────────────────────
# Unlike the ALB, the replication group IS a Terraform resource, so these
# pin by dimension directly — no discovery tricks. ElastiCache emits
# per-NODE metrics under CacheClusterId; with cluster mode disabled the
# member nodes are named <replication_group_id>-001..-00N, and this stack's
# single-node dev posture means -001 is the (only) primary. A multi-node
# env (redis_num_cache_clusters > 1) would want these per member — accepted
# single-node scope for now.
locals {
  redis_node_id = "${aws_elasticache_replication_group.redis.replication_group_id}-001"
}

# Memory first: the counter workload can't shrink (INCRBY forever, no TTL),
# so memory creep is this cache's one guaranteed slow failure. Redis at
# maxmemory with no eviction turns writes into errors — user-facing 500s.
resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "${local.name}-redis-memory"
  alarm_description   = "ElastiCache ${local.redis_node_id} memory above ${var.redis_memory_threshold_percent}% — the INCRBY counter only grows; sustained high memory ends in write errors."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.redis_memory_threshold_percent
  # Metrics lag node creation by a few minutes on a from-zero apply — that
  # gap must read GREEN, same reasoning as the ALB alarms.
  treat_missing_data = "notBreaching"

  namespace   = "AWS/ElastiCache"
  metric_name = "DatabaseMemoryUsagePercentage"
  statistic   = "Average"
  period      = 300
  dimensions  = { CacheClusterId = local.redis_node_id }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# EngineCPUUtilization (the Redis thread), not CPUUtilization (the host):
# Redis is single-threaded, so the engine thread pegging is the real
# saturation signal — host CPU on a 2-vCPU t4g.micro reads ~50% when the
# engine is already at 100%.
resource "aws_cloudwatch_metric_alarm" "redis_engine_cpu" {
  alarm_name          = "${local.name}-redis-engine-cpu"
  alarm_description   = "ElastiCache ${local.redis_node_id} engine CPU above ${var.redis_engine_cpu_threshold_percent}% — the single Redis thread is saturating; commands queue and latency climbs."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.redis_engine_cpu_threshold_percent
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ElastiCache"
  metric_name = "EngineCPUUtilization"
  statistic   = "Average"
  period      = 300
  dimensions  = { CacheClusterId = local.redis_node_id }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Saved Logs Insights queries — pre-canned console entry points into the 14
# days of every pod's lines (folder ${local.name}/). Saving them WITH
# log_group_names pre-selects the group when opened in the console.
# kubectl logs stays the local/degraded path.
resource "aws_cloudwatch_query_definition" "logs_p95_by_service" {
  # "(pending JSON logs)" suffix: the caveat travels to the console — these
  # queries return nothing until the JSON formatter lands (see the locals
  # header). Drop the suffix in the same PR that ships JSON logs.
  name            = "${local.name}/p95-by-service (pending JSON logs)"
  log_group_names = [aws_cloudwatch_log_group.container_insights["application"].name]
  query_string    = local.q_logs_p95
}

resource "aws_cloudwatch_query_definition" "logs_errors_recent" {
  name            = "${local.name}/errors-recent (pending JSON logs)"
  log_group_names = [aws_cloudwatch_log_group.container_insights["application"].name]
  query_string    = local.q_logs_errors
}

# Cost visibility: which service is the ingest bill. est_bytes ~ pre-metadata
# payload. Works today even on text logs — it needs only @message.
resource "aws_cloudwatch_query_definition" "logs_volume_by_service" {
  name            = "${local.name}/volume-by-service"
  log_group_names = [aws_cloudwatch_log_group.container_insights["application"].name]
  query_string    = local.q_logs_volume
}

# Dashboard: ALB metrics (2x2 — signals that flow free) plus a request-log
# row and a Redis row (dimension-pinned — the replication group is in
# state). Same Metrics Insights trick as the alarms for the ALB widgets — each
# "metrics" entry is an expression object instead of a [namespace, name,
# dim, value] tuple, so nothing needs the ALB's dimension pinned. The logs
# row reads the application group through Logs Insights "log" widgets,
# sharing its query strings with the saved queries above.
resource "aws_cloudwatch_dashboard" "alb" {
  dashboard_name = "${local.name}-alb"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Request Count (sum)"
          view   = "timeSeries"
          region = data.aws_region.current.region
          metrics = [
            [{
              expression = local.q_requests
              id         = "q1"
              period     = 300
              label      = "RequestCount"
            }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Target Response Time (avg)"
          view   = "timeSeries"
          region = data.aws_region.current.region
          metrics = [
            [{
              expression = local.q_avg_latency
              id         = "q1"
              period     = 300
              label      = "TargetResponseTime (avg)"
            }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "5xx (target + ELB)"
          view   = "timeSeries"
          region = data.aws_region.current.region
          metrics = [
            [{
              expression = local.q_target_5xx
              id         = "q1"
              period     = 300
              label      = "Target 5XX"
            }],
            [{
              expression = local.q_elb_5xx
              id         = "q2"
              period     = 300
              label      = "ELB 5XX"
            }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Healthy Host Count (min)"
          view   = "timeSeries"
          region = data.aws_region.current.region
          metrics = [
            [{
              expression = local.q_healthy_min
              id         = "q1"
              period     = 300
              label      = "HealthyHostCount"
            }]
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "App p95 from request logs (5m bins — fills when JSON logs land)"
          region = data.aws_region.current.region
          view   = "timeSeries"
          query  = "SOURCE '${aws_cloudwatch_log_group.container_insights["application"].name}' | ${local.q_logs_p95_bin}"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Recent 5xx (request logs — fills when JSON logs land)"
          region = data.aws_region.current.region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.container_insights["application"].name}' | ${local.q_logs_errors}"
        }
      },
      # Redis row: the two alarm metrics, dimension-pinned to the single
      # member node (see the ElastiCache alarms above for the -001 story).
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Redis Memory Usage (%)"
          view   = "timeSeries"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "CacheClusterId", local.redis_node_id]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "Redis Engine CPU (%)"
          view   = "timeSeries"
          region = data.aws_region.current.region
          metrics = [
            ["AWS/ElastiCache", "EngineCPUUtilization", "CacheClusterId", local.redis_node_id]
          ]
        }
      }
    ]
  })
}

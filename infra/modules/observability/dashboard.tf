# One dashboard per environment.
#   Row 1 (users' view): SLO status, request rate, error rate, latency p95
#   Row 2 (why):         alarm state, healthy tasks, ECS CPU/memory, RDS
#   Row 3 (detail):      the latest failing requests, from the app's JSON logs

data "aws_region" "current" {}

locals {
  region = data.aws_region.current.region

  # Same error-rate formula as the alarms (see alarms.tf), without the
  # minimum-traffic guard: the dashboard should show every failure.
  error_rate_metrics = [
    [{ id = "error_rate", label = "5xx error rate %", expression = "IF((FILL(requests,0) + FILL(elb5xx,0)) > 0, 100 * (FILL(app5xx,0) + FILL(elb5xx,0)) / (FILL(requests,0) + FILL(elb5xx,0)), 0)" }],
    ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { id = "requests", stat = "Sum", visible = false }],
    ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { id = "app5xx", stat = "Sum", visible = false }],
    ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { id = "elb5xx", stat = "Sum", visible = false }],
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      # ---- row 1 -------------------------------------------------------------------
      {
        type = "metric", x = 0, y = 0, width = 6, height = 6
        properties = {
          title  = "SLO (${var.slo_target_percent}% non-5xx): set time range to 1w"
          view   = "singleValue"
          region = local.region
          # One number over the whole selected time range, not per minute.
          setPeriodToTimeRange = true
          metrics = [
            [{ id = "availability", label = "Availability %", expression = "100 - error_rate" }],
            [{ id = "budget_used", label = "Error budget used %", expression = "100 * error_rate / ${100 - var.slo_target_percent}" }],
            [{ id = "error_rate", expression = "IF((FILL(requests,0) + FILL(elb5xx,0)) > 0, 100 * (FILL(app5xx,0) + FILL(elb5xx,0)) / (FILL(requests,0) + FILL(elb5xx,0)), 0)", visible = false }],
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { id = "requests", stat = "Sum", visible = false }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { id = "app5xx", stat = "Sum", visible = false }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { id = "elb5xx", stat = "Sum", visible = false }],
          ]
        }
      },
      {
        type = "metric", x = 6, y = 0, width = 6, height = 6
        properties = {
          title  = "Request rate (per minute)"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { label = "Requests" }],
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 6, height = 6
        properties = {
          title   = "Error rate (5xx %)"
          view    = "timeSeries"
          region  = local.region
          period  = 60
          metrics = local.error_rate_metrics
          yAxis   = { left = { min = 0 } }
          annotations = {
            horizontal = [
              { label = "SLO budget (${100 - var.slo_target_percent}%)", value = 100 - var.slo_target_percent, color = "#ff7f0e" },
              { label = "Alarm (${var.burn_rate * (100 - var.slo_target_percent)}%)", value = var.burn_rate * (100 - var.slo_target_percent), color = "#d62728" },
            ]
          }
        }
      },
      {
        type = "metric", x = 18, y = 0, width = 6, height = 6
        properties = {
          title  = "Latency (seconds, ALB to app)"
          view   = "timeSeries"
          region = local.region
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p95", label = "p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p99", label = "p99" }],
          ]
          yAxis = { left = { min = 0 } }
        }
      },

      # ---- row 2 -------------------------------------------------------------------
      {
        type = "alarm", x = 0, y = 6, width = 6, height = 6
        properties = {
          title = "Alarms"
          alarms = [
            aws_cloudwatch_composite_alarm.slo_at_risk.arn,
            aws_cloudwatch_metric_alarm.burn["1h"].arn,
            aws_cloudwatch_metric_alarm.burn["5m"].arn,
          ]
        }
      },
      {
        type = "metric", x = 6, y = 6, width = 6, height = 6
        properties = {
          title  = "Tasks passing /readyz"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Minimum"
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { label = "Healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", var.target_group_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { label = "Unhealthy", stat = "Maximum" }],
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 6, height = 6
        properties = {
          title  = "ECS service CPU / memory (%)"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { label = "CPU" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", var.service_name, { label = "Memory" }],
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 18, y = 6, width = 6, height = 6
        properties = {
          title  = "RDS"
          view   = "timeSeries"
          region = local.region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id, { label = "CPU %" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_id, { label = "Connections", yAxis = "right" }],
          ]
          yAxis = { left = { min = 0, max = 100 }, right = { min = 0 } }
        }
      },

      # ---- row 3 -------------------------------------------------------------------
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Latest errors (app logs: level error, or 5xx responses)"
          region = local.region
          view   = "table"
          query  = "SOURCE '${var.app_log_group_name}' | fields @timestamp, statusCode, method, route, durationMs, msg, reqId | filter level >= 50 or statusCode >= 500 | sort @timestamp desc | limit 50"
        }
      },
    ]
  })
}

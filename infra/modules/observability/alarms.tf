# SLO: 99.5% of requests succeed (non-5xx) over a rolling 7 days.
# Error budget: the 0.5% that may fail.
#
# Alarm = "SLO at risk": the budget is burning 14.4x faster than allowed.
# At 14.4x, a 7-day budget is gone in ~12 hours, so someone should look now.
# 14.4 x 0.5% = 7.2% of requests failing.
#
# Two windows, both must agree (composite alarm):
#   1 hour    -> proves it's sustained, not a blip (few false pages)
#   5 minutes -> proves it's still happening (alarm clears soon after the fix)
# This is the multi-window burn-rate pattern from the Google SRE workbook.
# Next step: a slow-burn pair (6x over 6 h + 30 min) that opens a ticket
# instead of paging.

locals {
  error_budget_percent = 100 - var.slo_target_percent               # 0.5
  burn_threshold       = var.burn_rate * local.error_budget_percent # 7.2

  alb_dims = { LoadBalancer = var.alb_arn_suffix }

  windows = {
    "1h" = { period = 3600, min_requests = var.min_requests_long }
    "5m" = { period = 300, min_requests = var.min_requests_short }
  }
}

# Why failed / (RequestCount + ELB 5xx):
# - Target 5xx = the app answered 500-599.
# - ELB 5xx = the ALB answered for the app: 502 (task crashed mid-request),
#   503 (no healthy task at all), 504 (timeout). A total outage shows up
#   only here, so it must count.
# - The ALB's RequestCount only counts requests it could send to a task, so
#   a 503 "no healthy targets" isn't in it. Adding ELB 5xx to the denominator
#   keeps an outage at ~100% instead of dividing by zero. (502/504 end up
#   counted twice, which slightly understates the rate: accepted.)
# FILL(..., 0): no 5xx datapoint means zero errors, not "unknown".
resource "aws_cloudwatch_metric_alarm" "burn" {
  for_each = local.windows

  alarm_name        = "${var.name}-slo-burn-${each.key}"
  alarm_description = "Error rate over the last ${each.key} is above ${local.burn_threshold}% (${var.burn_rate}x the ${var.slo_target_percent}% SLO's budget). Child of ${var.name}-slo-at-risk; no notifications of its own."

  comparison_operator = "GreaterThanThreshold"
  threshold           = local.burn_threshold
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  treat_missing_data  = "notBreaching" # no traffic = nothing failing

  metric_query {
    id          = "error_rate"
    label       = "5xx error rate % (${each.key})"
    return_data = true
    expression  = "IF((FILL(requests,0) + FILL(elb5xx,0)) >= ${each.value.min_requests}, 100 * (FILL(app5xx,0) + FILL(elb5xx,0)) / (FILL(requests,0) + FILL(elb5xx,0)), 0)"
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = local.alb_dims
      period      = each.value.period
      stat        = "Sum"
    }
  }

  metric_query {
    id = "app5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = local.alb_dims
      period      = each.value.period
      stat        = "Sum"
    }
  }

  metric_query {
    id = "elb5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = local.alb_dims
      period      = each.value.period
      stat        = "Sum"
    }
  }
}

# The alarm people get emailed about. RUNBOOK.md explains what to do.
resource "aws_cloudwatch_composite_alarm" "slo_at_risk" {
  alarm_name        = "${var.name}-slo-at-risk"
  alarm_description = "SLO at risk: more than ${local.burn_threshold}% of requests failing over both the last hour and the last 5 minutes. At this rate the 7-day error budget (${local.error_budget_percent}%) runs out in about ${floor(168 / var.burn_rate)} hours. Runbook: RUNBOOK.md in the repo."

  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.burn["1h"].alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.burn["5m"].alarm_name}\")"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn] # "resolved" email too
}

# ---- notifications ---------------------------------------------------------------------

# Not encrypted with the AWS-managed SNS key: CloudWatch can't publish to a
# topic using it (would need a customer-managed KMS key, ~$1/month). Alarm
# messages hold no user data, only alarm names and numbers.
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

# Email subscriptions start "pending": AWS emails a confirmation link that
# must be clicked before alerts are delivered.
resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

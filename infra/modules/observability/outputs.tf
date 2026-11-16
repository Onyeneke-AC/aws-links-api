output "dashboard_url" {
  value = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.this.dashboard_name}"
}

output "slo_alarm_name" {
  description = "The alarm that notifies people (RUNBOOK.md)."
  value       = aws_cloudwatch_composite_alarm.slo_at_risk.alarm_name
}

output "deployment_alarm_names" {
  description = "For the ECS service: if this fires during a deployment, ECS rolls back even though health checks pass."
  value       = [aws_cloudwatch_metric_alarm.burn["5m"].alarm_name]
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "alb_metrics_namespace" {
  value = var.alb_metrics_namespace
}

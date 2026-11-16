output "public_url" {
  description = "Public address (ALB, plain HTTP)."
  value       = module.edge.public_url
}

output "image_tag" {
  description = "The commit SHA currently deployed."
  value       = var.image_tag
}

output "cluster_name" {
  value = module.service.cluster_name
}

output "service_name" {
  value = module.service.service_name
}

output "log_group_name" {
  value = module.service.log_group_name
}

output "db_instance_id" {
  value = module.database.instance_id
}

output "dashboard_url" {
  value = module.observability.dashboard_url
}

output "slo_alarm_name" {
  value = module.observability.slo_alarm_name
}

# For scripts/traffic.sh on the AWS Emulator: where, and under which
# LoadBalancer dimension, to publish the metrics the alarms read.
output "alb_metrics_namespace" {
  value = module.observability.alb_metrics_namespace
}

output "alb_arn_suffix" {
  value = module.edge.alb_arn_suffix
}

output "alerts_topic_arn" {
  value = module.observability.alerts_topic_arn
}

output "public_url" {
  description = "Use this. HTTPS via CloudFront."
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

output "alb_dns_name" {
  description = "Direct ALB address: should answer 403 (proves the origin is locked to CloudFront)."
  value       = module.edge.alb_dns_name
}

output "db_instance_id" {
  value = module.database.instance_id
}

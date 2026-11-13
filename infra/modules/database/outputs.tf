output "address" {
  description = "DB hostname (becomes PGHOST in the task). Resolvable only inside the VPC."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret (JSON: username, password) that ECS injects at task start."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "instance_id" {
  description = "For CloudWatch alarms and dashboards."
  value       = aws_db_instance.this.identifier
}

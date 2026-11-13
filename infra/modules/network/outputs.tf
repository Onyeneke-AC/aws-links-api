output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "For the ALB and NAT gateway."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "For ECS tasks."
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "For RDS. No route outside the VPC."
  value       = aws_subnet.database[*].id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

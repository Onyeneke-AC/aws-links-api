output "public_url" {
  description = "The service's public address (plain HTTP, see alb.tf)."
  value       = "http://${aws_lb.this.dns_name}"
}

output "target_group_arn" {
  description = "For the ECS service to register its tasks."
  value       = aws_lb_target_group.app.arn

  # ECS rejects a target group that isn't attached to a listener yet. Making
  # the output wait means whatever uses it (the ECS service) waits too.
  depends_on = [aws_lb_listener.http]
}

# CloudWatch identifies ALB/target-group metrics by these "arn suffixes".
output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.app.arn_suffix
}

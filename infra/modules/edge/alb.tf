# Application Load Balancer: spreads requests over healthy ECS tasks.
#
# Listener rules, checked in priority order:
#   10  /metrics                         -> 404 (internal only, never public)
#   20  header X-Origin-Verify == secret -> forward to the app
#   default (anything else)              -> 403
# Only our CloudFront distribution knows the secret, so requests that bypass it
# (including via someone else's CloudFront distribution) are refused.

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false # CloudFront reaches it over the internet; SG allows CloudFront only
  subnets            = var.public_subnet_ids
  security_groups    = [var.alb_security_group_id]

  # Reject requests with malformed headers instead of passing them on.
  drop_invalid_header_fields = true

  # Must stay below the app's keep-alive (Fastify default 72 s); otherwise the
  # app can close a connection the ALB is about to reuse -> random 502s.
  idle_timeout = 60

  enable_deletion_protection = false # take-home: `make destroy` must work
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name}-app"
  vpc_id      = var.vpc_id
  port        = var.app_port
  protocol    = "HTTP"
  target_type = "ip" # Fargate tasks register by IP (awsvpc networking)

  # Readiness, not liveness: a task that can't reach the database gets no
  # traffic. During a deploy, new tasks that never pass this make the ECS
  # circuit breaker roll back.
  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2 # 2 passes (~20 s) before receiving traffic
    unhealthy_threshold = 3 # 3 failures (~30 s) before being taken out
  }

  # When a task is being stopped, the ALB stops sending it new requests and
  # gives in-flight ones this long to finish before ECS sends SIGTERM.
  deregistration_delay = 30

  lifecycle {
    create_before_destroy = true
  }
}

# Shared secret between CloudFront and the ALB. Stored in Terraform state: an
# accepted trade-off because it only proves "came through our CloudFront"; it
# protects no data. Rotate by replacing this resource and re-applying.
resource "random_password" "origin_verify" {
  length  = 32
  special = false
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP" # CloudFront terminates HTTPS for users (no domain -> no ALB cert)

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "Forbidden"
    }
  }
}

resource "aws_lb_listener_rule" "block_metrics" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/metrics"]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "404"
      message_body = "Not Found"
    }
  }
}

resource "aws_lb_listener_rule" "from_cloudfront" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

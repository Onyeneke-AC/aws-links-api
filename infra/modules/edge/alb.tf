# Application Load Balancer: the public entry point; spreads requests over
# healthy ECS tasks.
#
# Listener rules, checked in priority order:
#   10  /metrics          -> 404 (internal only, never public)
#   default (everything)  -> forward to the app
#
# Plain HTTP for now: no domain = no ACM certificate, and CloudFront (HTTPS on
# *.cloudfront.net) is blocked until the AWS account is verified. Next step is
# CloudFront in front again (see git history, commit f66d06f) or a domain +
# ACM cert with an HTTPS listener and an HTTP->HTTPS redirect.

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
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

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
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

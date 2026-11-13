# ECS Fargate: AWS runs our container; we never manage servers.
#   cluster -> service (keeps N tasks running, registers them with the ALB)
#           -> task definition (what to run: image, env, secrets, health check)

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  # Off: Container Insights bills per metric; our dashboard uses the ALB's
  # free metrics instead. Turn on when per-task CPU/memory detail is needed.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

# Terraform-owned so it has a retention period and is removed by destroy.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}-api"
  retention_in_days = var.log_retention_days
}

locals {
  container_name = "api"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # each task gets its own IP + security group
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  # No task_role_arn on purpose: see iam.tf.

  # Graviton: ~20% cheaper than x86, and matches the arm64 image built on a Mac.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = "${data.aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

      # Plain config. PGSSLMODE=verify-full is baked into the image.
      environment = [
        { name = "PORT", value = tostring(var.container_port) },
        { name = "LOG_LEVEL", value = var.log_level },
        { name = "PUBLIC_BASE_URL", value = var.public_base_url },
        { name = "PGHOST", value = var.db_host },
        { name = "PGPORT", value = tostring(var.db_port) },
        { name = "PGDATABASE", value = var.db_name },
      ]

      # Fetched from Secrets Manager by the ECS agent at task start and set as
      # env vars inside the container. "<arn>:<json key>::" picks one field.
      # The values never appear in the task definition, Terraform state or logs.
      secrets = [
        { name = "PGUSER", valueFrom = "${var.db_secret_arn}:username::" },
        { name = "PGPASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
      ]

      # ECS ignores the Dockerfile HEALTHCHECK, so it's repeated here.
      # Liveness only (/healthz): an unhealthy container is restarted.
      healthCheck = {
        command     = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:${var.container_port}/healthz || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }

      # Small init process as PID 1: forwards SIGTERM to node and reaps zombies.
      linuxParameters = { initProcessEnabled = true }

      # The app never writes to disk; an attacker can't drop files either.
      readonlyRootFilesystem = true

      # SIGTERM -> app drains in-flight requests (server.js allows 10 s) -> SIGKILL after 20 s.
      stopTimeout = 20

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "api"
          # If CloudWatch is slow, buffer and (worst case) drop log lines
          # rather than block the app and stall requests.
          "mode"            = "non-blocking"
          "max-buffer-size" = "25m"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name             = "${var.name}-api"
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false # private subnets; outbound via NAT
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  # Ignore ALB health results for the first 30 s while the app boots.
  health_check_grace_period_seconds = 30

  # Rolling deploy: start new tasks first (up to 200%), never drop below 100%,
  # so capacity never shrinks during a deploy.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Automatic rollback: if new tasks keep failing to become healthy (crash at
  # boot, or the ALB's /readyz check fails), ECS stops the deployment and goes
  # back to the last working task definition.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Optional second trigger: roll back if an alarm (e.g. 5xx rate) fires
  # during the deployment, even if health checks pass.
  dynamic "alarms" {
    for_each = length(var.deployment_alarm_names) > 0 ? [1] : []
    content {
      alarm_names = var.deployment_alarm_names
      enable      = true
      rollback    = true
    }
  }

  # `terraform apply` waits until the deployment finishes, so CI sees it.
  # Caveat: after a circuit-breaker rollback the service is "steady" again on
  # the OLD version, so CI must also check the deployment outcome itself.
  wait_for_steady_state = true

  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true
}

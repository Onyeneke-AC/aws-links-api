# RDS Postgres in the isolated database subnets. The master password is generated and stored
# by RDS itself in Secrets Manager (manage_master_user_password), so it never
# appears in our code, the image, CI logs or Terraform state.

locals {
  identifier = "${var.name}-db"
}

# Which subnets RDS may place the instance in (private only, 2+ AZs).
resource "aws_db_subnet_group" "this" {
  name       = local.identifier
  subnet_ids = var.subnet_ids
  tags       = { Name = local.identifier }
}

# Our own parameter group (the default one can't be edited).
resource "aws_db_parameter_group" "this" {
  name   = local.identifier
  family = "postgres${var.engine_version}"

  # Refuse unencrypted connections. Already the default on Postgres 15+, set
  # explicitly so it's visible in code and can't silently change.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Log each connection's arrival, authentication and authorization: the first
  # place to look when the password was rotated or a client is misconfigured.
  # (Postgres 18 turned this from on/off into a list; this list = the old "on".
  # Failed logins are always logged as FATAL regardless.)
  parameter {
    name  = "log_connections"
    value = var.log_connections
  }

  # Log any statement slower than 500 ms (helps with latency incidents).
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }

  # A changed family (major upgrade) needs a new group before the old one goes.
  lifecycle {
    create_before_destroy = true
  }
}

# RDS would create this log group on its own, but then Terraform wouldn't own
# it: it would have no retention and survive `make destroy`. Creating it first
# with the exact name RDS uses fixes both.
resource "aws_cloudwatch_log_group" "postgres" {
  name              = "/aws/rds/instance/${local.identifier}/postgresql"
  retention_in_days = var.log_retention_days
}

resource "aws_db_instance" "this" {
  identifier     = local.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = "links"
  username = "links"
  # RDS generates the password, stores it in Secrets Manager (JSON with
  # "username" and "password" keys) and rotates it every 7 days by default.
  manage_master_user_password = true

  # Storage: encrypted with the AWS-managed RDS key; grows automatically up to
  # max_allocated_storage instead of filling up.
  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_encrypted     = true

  # Network: database subnets (no route out), no public IP, Postgres only from the app SG.
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  parameter_group_name            = aws_db_parameter_group.this.name
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # Patching: minor versions upgrade automatically in the maintenance window.
  auto_minor_version_upgrade = true
  # Apply changes now instead of waiting for the weekly maintenance window, so
  # a deploy does what its plan says. A real prod DB might prefer the window.
  apply_immediately = true

  backup_retention_period = var.backup_retention_days
  copy_tags_to_snapshot   = true

  # Take-home trade-off so `make destroy` leaves nothing behind. A real prod DB:
  # deletion_protection = true, skip_final_snapshot = false.
  deletion_protection      = var.deletion_protection
  skip_final_snapshot      = true
  delete_automated_backups = true

  depends_on = [aws_cloudwatch_log_group.postgres]

  tags = { Name = local.identifier }
}

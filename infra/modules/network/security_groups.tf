# The whole traffic matrix in one file, so it can be reviewed at a glance.
# Security groups deny everything by default; each rule below is one allowed
# flow, and sources are other security groups (not IP ranges) wherever possible.
#
#   internet --80--> ALB --app_port--> ECS task --5432--> RDS
#                                             \--443--> AWS APIs (ECR, Secrets
#                                                       Manager, CloudWatch Logs)

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB: HTTP from the internet"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-alb" }
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "ECS tasks: app port from the ALB only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-app" }
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "RDS: Postgres from ECS tasks only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-db" }
}

# ---- ALB ----------------------------------------------------------------------

# The ALB is the public entry point. Plain HTTP: no domain means no ACM
# certificate, and CloudFront (HTTPS on *.cloudfront.net) is blocked until the
# AWS account is verified. Known gap, see DESIGN.md.
resource "aws_vpc_security_group_ingress_rule" "alb_from_internet" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Requests and health checks to ECS tasks"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

# ---- ECS tasks ------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "From the ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "Postgres"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}

# 0.0.0.0/0 because AWS public API endpoints (ECR, Secrets Manager, CloudWatch
# Logs) have no fixed IPs. HTTPS only, and only via the NAT gateway. Tightening
# this means VPC interface endpoints (~$15/month each per env); next week.
resource "aws_vpc_security_group_egress_rule" "app_to_aws_apis" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# ---- RDS -------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from ECS tasks only"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
}
# No egress rules on the DB: it never needs to start a connection.

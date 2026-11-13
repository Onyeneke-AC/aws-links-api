# One VPC per environment. Layout for vpc_cidr = 10.10.0.0/16, 2 AZs:
#
#   public  10.10.0.0/24  10.10.1.0/24   ALB, NAT gateway (things that face the internet)
#   private 10.10.10.0/24 10.10.11.0/24  ECS tasks, RDS (no route *from* the internet)
#
# Private subnets reach out (ECR, Secrets Manager, CloudWatch) through one NAT
# gateway; nothing on the internet can open a connection into them.

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # needed for RDS endpoint names and VPC endpoints

  tags = { Name = "${var.name}-vpc" }
}

# Lock down the VPC's built-in default security group (it allows all traffic
# between its members). Nothing uses it; this stops anyone using it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-unused" }
}

# ---- public subnets -----------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 24 - tonumber(split("/", var.vpc_cidr)[1]), count.index)

  # Nothing we run here should get a public IP just by being launched.
  # The ALB and NAT gateway get theirs explicitly.
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---- private subnets ------------------------------------------------------------

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 24 - tonumber(split("/", var.vpc_cidr)[1]), 10 + count.index)

  tags = { Name = "${var.name}-private-${local.azs[count.index]}", Tier = "private" }
}

# ONE NAT gateway per environment, in the first AZ (cost trade-off, see DESIGN.md).
# If that AZ fails, tasks in the other AZ keep serving requests (the ALB routes
# around them) but can't reach ECR/Secrets Manager, so they can't *start* new
# tasks until it recovers. Production fix: one NAT per AZ, or a regional NAT
# gateway, for roughly +$1/day per extra AZ.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.name}-nat" }

  depends_on = [aws_internet_gateway.this] # NAT needs a working IGW behind it
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Free S3 gateway endpoint. ECR stores image layers in S3, so image pulls go
# straight to S3 instead of through the NAT gateway (which charges per GB).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.name}-s3" }
}

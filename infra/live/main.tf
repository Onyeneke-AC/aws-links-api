# Wiring only: every resource lives in a module. Data flows top to bottom:
#   network  -> VPC, subnets, security groups
#   database -> RDS in the private subnets (+ RDS-managed secret)
#   edge     -> ALB in the public subnets + CloudFront in front
#   service  -> ECS tasks in the private subnets, registered with edge's target
#               group, reading database's address and secret

locals {
  name = "${var.project}-${var.environment}" # e.g. links-dev
}

module "network" {
  source = "../modules/network"

  name     = local.name
  vpc_cidr = var.vpc_cidr
}

module "database" {
  source = "../modules/database"

  name                  = local.name
  subnet_ids            = module.network.private_subnet_ids
  security_group_id     = module.network.db_security_group_id
  instance_class        = var.db_instance_class
  backup_retention_days = var.db_backup_retention_days
  log_retention_days    = var.log_retention_days
}

module "edge" {
  source = "../modules/edge"

  name                  = local.name
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.network.alb_security_group_id
}

module "service" {
  source = "../modules/service"

  name                = local.name
  ecr_repository_name = var.ecr_repository_name
  image_tag           = var.image_tag
  desired_count       = var.desired_count
  log_level           = var.log_level
  log_retention_days  = var.log_retention_days

  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.app_security_group_id
  target_group_arn  = module.edge.target_group_arn
  public_base_url   = module.edge.public_url

  db_host       = module.database.address
  db_port       = module.database.port
  db_name       = module.database.db_name
  db_secret_arn = module.database.master_user_secret_arn
}

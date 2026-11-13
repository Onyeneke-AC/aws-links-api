environment              = "prod"
vpc_cidr                 = "10.20.0.0/16"
desired_count            = 2 # one task per AZ: survives losing a task or an AZ
db_backup_retention_days = 7
log_level                = "info"
log_retention_days       = 30

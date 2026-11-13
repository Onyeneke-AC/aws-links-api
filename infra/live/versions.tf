# Root stack for one environment. The same code serves dev and prod; only the
# tfvars file and the state key differ (`make up ENV=dev|prod`).

terraform {
  required_version = ">= 1.10, < 2.0" # 1.10+ for S3-native state locking

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73" # exact versions + hashes pinned in .terraform.lock.hcl
    }
  }

  # Partial config: the Makefile supplies bucket (derived from the account ID,
  # so the repo works in any account) and key = live/<env>/terraform.tfstate.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Stack       = "live"
      ManagedBy   = "terraform"
    }
  }
}

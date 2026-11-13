# Bootstrap: the few account-level things everything else depends on.
# Applied once from a laptop (`make bootstrap`); all other changes go via CI.

terraform {
  required_version = ">= 1.10, < 2.0" # 1.10+ for S3-native state locking

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73" # exact version + hashes pinned in .terraform.lock.hcl
    }
  }

  # Partial config: bucket/key/region come from `make bootstrap`
  # (-backend-config). On the very first run the bucket doesn't exist yet, so
  # the Makefile temporarily overrides this with a local backend, then
  # migrates the state into the bucket it just created.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      Stack     = "bootstrap"
      ManagedBy = "terraform"
      Repo      = var.github_repo
    }
  }
}

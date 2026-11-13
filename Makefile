# Entry point for humans. Written for GNU Make 3.81 (macOS default): no
# .ONESHELL, so multi-line recipes are joined with `&& \`.

AWS_REGION ?= eu-west-1
export AWS_REGION

PROJECT       := links
BOOTSTRAP_DIR := infra/bootstrap
TF_BOOTSTRAP  := terraform -chdir=$(BOOTSTRAP_DIR)

# Recursive (=) on purpose: only calls AWS when a target actually uses it.
ACCOUNT_ID    = $(shell aws sts get-caller-identity --query Account --output text)
STATE_BUCKET  = $(PROJECT)-tfstate-$(ACCOUNT_ID)-$(AWS_REGION)
BOOTSTRAP_BACKEND = -backend-config=bucket=$(STATE_BUCKET) \
                    -backend-config=key=bootstrap/terraform.tfstate \
                    -backend-config=region=$(AWS_REGION) \
                    -backend-config=use_lockfile=true \
                    -backend-config=encrypt=true
LOCAL_BACKEND_OVERRIDE := $(BOOTSTRAP_DIR)/backend_override.tf

.DEFAULT_GOAL := help
.PHONY: help lint test db-up db-down aws-check bootstrap bootstrap-destroy tf-fmt tf-validate

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

# ---- app ---------------------------------------------------------------------
lint: ## Lint the app
	npm run lint

test: db-up ## Run unit + integration tests (starts local Postgres)
	npm test

db-up: ## Start local Postgres (docker compose)
	npm run db:up

db-down: ## Stop local Postgres and delete its data
	npm run db:down

# ---- terraform hygiene -------------------------------------------------------
tf-fmt: ## Check Terraform formatting
	terraform fmt -check -recursive infra

tf-validate: ## Validate Terraform without touching AWS
	$(TF_BOOTSTRAP) init -backend=false -input=false >/dev/null && $(TF_BOOTSTRAP) validate

# Fail early (instead of computing a bucket name like "links-tfstate--eu-west-1")
# and show which account is about to be changed.
aws-check: ## Show the AWS account/region in use; fail if not logged in
	@test -n "$(ACCOUNT_ID)" || { echo "!! No AWS credentials. Run: aws sso login --profile <profile> and export AWS_PROFILE"; exit 1; }
	@echo ">> AWS account $(ACCOUNT_ID), region $(AWS_REGION), state bucket $(STATE_BUCKET)"

# ---- bootstrap (laptop, one-time) ----------------------------------------------
# The state bucket is created by this same stack, so on the first run there is
# nowhere to store state yet. Flow:
#   1. temporary local backend (backend_override.tf) -> apply
#   2. remove the override -> `init -migrate-state` copies the state into S3
# A leftover local terraform.tfstate means a first run didn't finish: resume it
# locally rather than starting fresh against an empty remote state.
bootstrap: aws-check ## Create/update state bucket, ECR repo, GitHub OIDC provider
	@if [ -f $(BOOTSTRAP_DIR)/terraform.tfstate ] || ! aws s3api head-bucket --bucket $(STATE_BUCKET) 2>/dev/null; then \
	  echo ">> First run: local state, then migrate it into s3://$(STATE_BUCKET)" && \
	  printf 'terraform {\n  backend "local" {}\n}\n' > $(LOCAL_BACKEND_OVERRIDE) && \
	  $(TF_BOOTSTRAP) init -input=false -reconfigure && \
	  $(TF_BOOTSTRAP) apply -var region=$(AWS_REGION) && \
	  rm -f $(LOCAL_BACKEND_OVERRIDE) && \
	  $(TF_BOOTSTRAP) init -input=false -migrate-state -force-copy $(BOOTSTRAP_BACKEND) && \
	  rm -f $(BOOTSTRAP_DIR)/terraform.tfstate $(BOOTSTRAP_DIR)/terraform.tfstate.backup && \
	  echo ">> Bootstrap state now lives in s3://$(STATE_BUCKET)/bootstrap/terraform.tfstate"; \
	else \
	  echo ">> State bucket exists: using remote state" && \
	  $(TF_BOOTSTRAP) init -input=false -reconfigure $(BOOTSTRAP_BACKEND) && \
	  $(TF_BOOTSTRAP) apply -var region=$(AWS_REGION); \
	fi

# Reverse of the above: pull state back to local (the bucket is about to be
# deleted), destroy, clean up. Refuses while any environment state still exists,
# because deleting the bucket would orphan those environments' resources.
bootstrap-destroy: aws-check ## Destroy bootstrap (run after every environment is destroyed)
	@if aws s3 ls s3://$(STATE_BUCKET)/live/ 2>/dev/null | grep -q .; then \
	  echo "!! Environment state still present under s3://$(STATE_BUCKET)/live/ - destroy envs first"; exit 1; \
	fi
	$(TF_BOOTSTRAP) init -input=false -reconfigure $(BOOTSTRAP_BACKEND)
	printf 'terraform {\n  backend "local" {}\n}\n' > $(LOCAL_BACKEND_OVERRIDE)
	$(TF_BOOTSTRAP) init -input=false -migrate-state -force-copy
	$(TF_BOOTSTRAP) destroy -var region=$(AWS_REGION)
	rm -f $(LOCAL_BACKEND_OVERRIDE) $(BOOTSTRAP_DIR)/terraform.tfstate $(BOOTSTRAP_DIR)/terraform.tfstate.backup

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

# The GitHub repo whose Actions may assume the CI roles, written the way GitHub's
# OIDC token names it: owner@<owner-id>/repo@<repo-id>. Detected from the git
# remote you cloned from (gh fills in {owner}/{repo}). Empty (no gh, not logged
# in, not a GitHub clone) = bootstrap creates no CI roles, so running it in
# someone else's account never grants a repo access there.
# Override: make bootstrap GITHUB_OIDC_REPO=owner@123/repo@456
GITHUB_OIDC_REPO ?= $(shell gh api 'repos/{owner}/{repo}' --jq '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"' 2>/dev/null)
BOOTSTRAP_VARS = -var region=$(AWS_REGION) -var 'github_oidc_repo=$(GITHUB_OIDC_REPO)'

# ---- environments ----
ENV      ?= dev
LIVE_DIR := infra/live
TF_LIVE  := terraform -chdir=$(LIVE_DIR)
LIVE_BACKEND = -backend-config=bucket=$(STATE_BUCKET) \
               -backend-config=key=live/$(ENV)/terraform.tfstate \
               -backend-config=region=$(AWS_REGION) \
               -backend-config=use_lockfile=true \
               -backend-config=encrypt=true
# Image tag = full commit SHA, so every running container traces to a commit.
IMAGE_TAG ?= $(shell git rev-parse HEAD)
ECR_REPO  := links-api
REGISTRY   = $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
IMAGE      = $(REGISTRY)/$(ECR_REPO):$(IMAGE_TAG)
LIVE_VARS  = -var-file=envs/$(ENV).tfvars -var region=$(AWS_REGION) -var image_tag=$(IMAGE_TAG)

.DEFAULT_GOAL := help
.PHONY: help lint test db-up db-down aws-check bootstrap bootstrap-destroy tf-fmt tf-validate \
        env-check live-init push-image plan up deploy image-exists rollout-check smoke destroy teardown

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
	@# Own data dir: the normal .terraform remembers the S3 backend, and even
	@# `init -backend=false` then wants AWS credentials.
	@for d in $(BOOTSTRAP_DIR) $(LIVE_DIR); do \
	  echo ">> $$d" && export TF_DATA_DIR=.terraform/validate && \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; \
	done

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
bootstrap: aws-check ## Create/update state bucket, ECR repo, GitHub OIDC provider, CI roles
	@repo='$(GITHUB_OIDC_REPO)'; if [ -n "$$repo" ]; then \
	  echo ">> CI roles will trust GitHub repo $$repo"; \
	else \
	  echo ">> No GitHub repo detected (gh missing/logged out, or not a GitHub clone): CI roles skipped"; \
	fi
	@if [ -f $(BOOTSTRAP_DIR)/terraform.tfstate ] || ! aws s3api head-bucket --bucket $(STATE_BUCKET) 2>/dev/null; then \
	  echo ">> First run: local state, then migrate it into s3://$(STATE_BUCKET)" && \
	  printf 'terraform {\n  backend "local" {}\n}\n' > $(LOCAL_BACKEND_OVERRIDE) && \
	  $(TF_BOOTSTRAP) init -input=false -reconfigure && \
	  $(TF_BOOTSTRAP) apply $(BOOTSTRAP_VARS) && \
	  rm -f $(LOCAL_BACKEND_OVERRIDE) && \
	  $(TF_BOOTSTRAP) init -input=false -migrate-state -force-copy $(BOOTSTRAP_BACKEND) && \
	  rm -f $(BOOTSTRAP_DIR)/terraform.tfstate $(BOOTSTRAP_DIR)/terraform.tfstate.backup && \
	  echo ">> Bootstrap state now lives in s3://$(STATE_BUCKET)/bootstrap/terraform.tfstate"; \
	else \
	  echo ">> State bucket exists: using remote state" && \
	  $(TF_BOOTSTRAP) init -input=false -reconfigure $(BOOTSTRAP_BACKEND) && \
	  $(TF_BOOTSTRAP) apply $(BOOTSTRAP_VARS); \
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
	$(TF_BOOTSTRAP) destroy $(BOOTSTRAP_VARS) $(DESTROY_ARGS)
	rm -f $(LOCAL_BACKEND_OVERRIDE) $(BOOTSTRAP_DIR)/terraform.tfstate $(BOOTSTRAP_DIR)/terraform.tfstate.backup

# ---- environments: make plan|up|smoke|destroy ENV=dev|prod -----------------------
# `make up` is the laptop path (first deploy, clean-clone test). Afterwards CI
# runs the same two steps: push the commit's image, then terraform apply.

env-check:
	@case "$(ENV)" in dev|prod) ;; *) echo "!! ENV must be dev or prod (got '$(ENV)')"; exit 1;; esac

# -reconfigure: dev and prod share this directory, so point it at the right
# state each time (never migrate one environment's state into the other's).
live-init: aws-check env-check
	$(TF_LIVE) init -input=false -reconfigure $(LIVE_BACKEND)

# ECR tags are immutable: if this commit's image is already there, reuse it
# ("build once, promote"). Refuses to stamp uncommitted changes with a commit
# SHA they don't belong to.
push-image: aws-check ## Build the arm64 image for HEAD and push it to ECR (skips if present)
	@if aws ecr describe-images --repository-name $(ECR_REPO) --image-ids imageTag=$(IMAGE_TAG) >/dev/null 2>&1; then \
	  echo ">> $(ECR_REPO):$(IMAGE_TAG) already in ECR, not rebuilding"; \
	else \
	  test -z "$$(git status --porcelain -- Dockerfile .dockerignore package.json package-lock.json .npmrc src)" || \
	    { echo "!! Uncommitted changes in files that go into the image: commit first"; exit 1; } && \
	  aws ecr get-login-password | docker login --username AWS --password-stdin $(REGISTRY) && \
	  docker buildx build --platform linux/arm64 --provenance=false -t $(IMAGE) --push . ; \
	fi

# PLAN_ARGS lets CI add flags (e.g. -no-color) while running the same target.
plan: live-init ## Show what `make up` would change (ENV=dev|prod)
	$(TF_LIVE) plan $(LIVE_VARS) $(PLAN_ARGS)

up: push-image deploy ## Laptop: build + push the image for HEAD, then deploy it (ENV=dev|prod)

# Deploy an image that is already in ECR. CI calls this directly (its build
# job pushed the image); APPLY_ARGS lets it add -auto-approve.
deploy: image-exists live-init ## Deploy IMAGE_TAG (must already be in ECR) to ENV
	$(TF_LIVE) apply $(LIVE_VARS) $(APPLY_ARGS)
	@echo ">> $(ENV) is live at $$($(TF_LIVE) output -raw public_url)   next: make smoke ENV=$(ENV)"

image-exists: aws-check
	@aws ecr describe-images --repository-name $(ECR_REPO) --image-ids imageTag=$(IMAGE_TAG) >/dev/null 2>&1 || \
	  { echo "!! $(ECR_REPO):$(IMAGE_TAG) is not in ECR (run make push-image, or let CI build it)"; exit 1; }

# terraform apply can "succeed" after ECS rolled back to the old image; this
# checks what is actually running (scripts/check-rollout.sh).
rollout-check: live-init ## Fail if ENV isn't running IMAGE_TAG on all tasks (e.g. rolled back)
	scripts/check-rollout.sh "$$($(TF_LIVE) output -raw cluster_name)" "$$($(TF_LIVE) output -raw service_name)" $(IMAGE_TAG)

smoke: live-init ## End-to-end test of a deployed environment
	scripts/smoke.sh "$$($(TF_LIVE) output -raw public_url)"

# After a successful destroy the state file is empty but still exists, which
# would block bootstrap-destroy. Delete it only if Terraform tracks nothing
# (the bucket is versioned, so it stays recoverable). `state list` failing must
# stop us: its empty output would otherwise look like "nothing left".
destroy: live-init ## Delete everything in an environment (ENV=dev|prod)
	$(TF_LIVE) destroy $(LIVE_VARS) $(DESTROY_ARGS)
	@left=$$($(TF_LIVE) state list) || { echo "!! Could not read state; not deleting it"; exit 1; }; \
	if [ -z "$$left" ]; then \
	  aws s3 rm s3://$(STATE_BUCKET)/live/$(ENV)/terraform.tfstate && echo ">> $(ENV) destroyed, empty state removed"; \
	else \
	  echo "!! Resources still in state, keeping it:" && $(TF_LIVE) state list; exit 1; \
	fi

# ---- everything ------------------------------------------------------------------
# One command, one confirmation: type the account ID (so it can't be confirmed
# on reflex, or in the wrong account), then prod, dev and bootstrap are
# destroyed without further prompts, in that order: environments first, because
# their state lives in the bucket bootstrap deletes. Environments without state
# are skipped. Stops at the first failure (re-run it to resume).
teardown: aws-check ## Destroy EVERYTHING: prod, dev, then bootstrap (state bucket, ECR, CI roles)
	@printf '!! This deletes prod, dev and bootstrap in AWS account %s.\n   Type the account ID to confirm: ' "$(ACCOUNT_ID)"; \
	read answer; \
	[ "$$answer" = "$(ACCOUNT_ID)" ] || { echo ">> Aborted, nothing deleted"; exit 1; }
	@for e in prod dev; do \
	  if aws s3api head-object --bucket $(STATE_BUCKET) --key live/$$e/terraform.tfstate >/dev/null 2>&1; then \
	    echo ">> Destroying $$e" && $(MAKE) --no-print-directory destroy ENV=$$e DESTROY_ARGS=-auto-approve || exit 1; \
	  else \
	    echo ">> $$e: no state, nothing to destroy"; \
	  fi; \
	done
	@echo ">> Destroying bootstrap" && $(MAKE) --no-print-directory bootstrap-destroy DESTROY_ARGS=-auto-approve
	@echo ">> Teardown complete: nothing from this project is left in account $(ACCOUNT_ID)"

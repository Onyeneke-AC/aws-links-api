# Entry point for humans. Written for GNU Make 3.81 (macOS default): no
# .ONESHELL, so multi-line recipes are joined with `&& \`.

AWS_REGION ?= eu-west-1
export AWS_REGION

# ---- AWS Emulator mode (EMULATOR=1) ----------------------------------------------
# `make emu-up`, then any target with EMULATOR=1 runs against AWS's local
# emulator instead of an AWS account: same Terraform, same targets. Every AWS
# CLI/SDK/Terraform call is pointed at it, with the per-run keys and CA
# certificate it writes into .emulator/. Real AWS credentials in the shell are
# dropped for these runs, so EMULATOR=1 can never reach a real account.
EMULATOR ?=
EMU_PORT  ?= 9297
EMU_HOME  := $(CURDIR)/.emulator
EMU_DIR   := $(EMU_HOME)/.aws/emulator/$(EMU_PORT)
EMU_IMAGE := links-aws-emulator
EMU_NAME  := links-aws-emulator
ifeq ($(EMULATOR),1)
export AWS_ENDPOINT_URL := https://127.0.0.1:$(EMU_PORT)
# S3 Control puts the account ID in front of the host (000000000000.<host>):
# that resolves for localhost, not for an IP. Terraform reads bucket tags this way.
export AWS_ENDPOINT_URL_S3_CONTROL := https://localhost:$(EMU_PORT)
export AWS_SHARED_CREDENTIALS_FILE := $(EMU_DIR)/emulator_credentials
export AWS_CONFIG_FILE := $(EMU_DIR)/config
export AWS_CA_BUNDLE := $(EMU_DIR)/ca.pem
export AWS_EC2_METADATA_DISABLED := true
export AWS_DISABLE_HOST_PREFIX_INJECTION := true
unexport AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
TF_EMULATOR_VAR := -var emulator=true
# Make before 4.4 (macOS ships 3.81) doesn't pass exported variables to
# $(shell ...), so the account lookup below gets them spelled out.
SHELL_AWS_ENV := env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
  AWS_ENDPOINT_URL=$(AWS_ENDPOINT_URL) AWS_SHARED_CREDENTIALS_FILE=$(AWS_SHARED_CREDENTIALS_FILE) \
  AWS_CONFIG_FILE=$(AWS_CONFIG_FILE) AWS_CA_BUNDLE=$(AWS_CA_BUNDLE) AWS_EC2_METADATA_DISABLED=true
endif

PROJECT       := links
BOOTSTRAP_DIR := infra/bootstrap
TF_BOOTSTRAP  := terraform -chdir=$(BOOTSTRAP_DIR)

# Recursive (=) on purpose: only calls AWS when a target actually uses it.
ACCOUNT_ID    = $(shell $(SHELL_AWS_ENV) aws sts get-caller-identity --query Account --output text)
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
BOOTSTRAP_VARS = -var region=$(AWS_REGION) -var 'github_oidc_repo=$(GITHUB_OIDC_REPO)' $(TF_EMULATOR_VAR)

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
ifeq ($(EMULATOR),1)
# The emulator's registry serves pulls only, so the image goes in through the
# ECR upload API (the calls `docker push` makes to ECR behind the scenes).
PUSH_IMAGE = docker buildx build --platform linux/arm64 --provenance=false -t $(ECR_REPO):$(IMAGE_TAG) --load . && \
             scripts/ecr-api-push.sh $(ECR_REPO):$(IMAGE_TAG) $(ECR_REPO) $(IMAGE_TAG)
else
PUSH_IMAGE = aws ecr get-login-password | docker login --username AWS --password-stdin $(REGISTRY) && \
             docker buildx build --platform linux/arm64 --provenance=false -t $(IMAGE) --push .
endif
LIVE_VARS  = -var-file=envs/$(ENV).tfvars -var region=$(AWS_REGION) -var image_tag=$(IMAGE_TAG) $(TF_EMULATOR_VAR)

MINUTES   ?= 10
# Where an environment answers: its load balancer on AWS. On the emulator the
# load balancer can't forward, so it's the app container emu-run publishes.
APP_PORT   = $(if $(filter prod,$(ENV)),8081,8080)
ifeq ($(EMULATOR),1)
ENV_URL    = echo http://127.0.0.1:$(APP_PORT)
else
ENV_URL    = $(TF_LIVE) output -raw public_url
endif

.DEFAULT_GOAL := help
.PHONY: help lint test db-up db-down aws-check bootstrap bootstrap-destroy tf-fmt tf-validate \
        env-check live-init push-image plan up deploy image-exists rollout-check smoke destroy teardown \
        emu-up emu-down emu-only emu-run chaos-db emu-chaos-test traffic alarms

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
	@echo ">> AWS account $(ACCOUNT_ID)$(if $(TF_EMULATOR_VAR), (AWS Emulator at $(AWS_ENDPOINT_URL)),), region $(AWS_REGION), state bucket $(STATE_BUCKET)"

# ---- AWS Emulator (local, no AWS account) ----------------------------------------
# State lives in the emulator's memory: emu-down forgets everything it held.
emu-up: ## Start the AWS Emulator locally (then add EMULATOR=1 to any target)
	docker build -q -t $(EMU_IMAGE) tools/aws-emulator >/dev/null
	@mkdir -p $(EMU_HOME)
	@docker rm -f $(EMU_NAME) >/dev/null 2>&1 || true
	@rm -rf $(EMU_DIR)
	docker run -d --name $(EMU_NAME) --user "$$(id -u):$$(id -g)" --memory=2g \
	  -p 127.0.0.1:$(EMU_PORT):$(EMU_PORT) -e HOME=$(EMU_HOME) -v $(EMU_HOME):$(EMU_HOME) \
	  $(EMU_IMAGE) -p $(EMU_PORT) >/dev/null
	@for i in $$(seq 1 30); do \
	  curl -fs --cacert $(EMU_DIR)/ca.pem https://127.0.0.1:$(EMU_PORT)/__admin/health >/dev/null 2>&1 && break; sleep 1; \
	done; curl -fs --cacert $(EMU_DIR)/ca.pem https://127.0.0.1:$(EMU_PORT)/__admin/health >/dev/null || \
	  { echo "!! Emulator not healthy:"; docker logs --tail 20 $(EMU_NAME); exit 1; }
	@echo ">> AWS Emulator $$(docker exec $(EMU_NAME) aws-emulator --version | head -1 | cut -d' ' -f2) up at https://127.0.0.1:$(EMU_PORT)"
	@echo "   next: make bootstrap EMULATOR=1 && make up ENV=dev EMULATOR=1"

emu-down: ## Stop the AWS Emulator (and any emu-run containers) and forget everything
	@docker rm -f $(EMU_NAME) $$(docker ps -aq --filter label=links-emulator) >/dev/null 2>&1 || true
	@docker network rm $$(docker network ls -q --filter label=links-emulator) >/dev/null 2>&1 || true
	@docker volume rm $$(docker volume ls -q --filter label=links-emulator) >/dev/null 2>&1 || true
	rm -rf $(EMU_HOME)

emu-only:
	@test "$(EMULATOR)" = 1 || { echo "!! This target is for the AWS Emulator: add EMULATOR=1"; exit 1; }

# The emulator records ECS tasks without running them: this runs the service's
# task definition for real (Postgres 18 standing in for RDS) and subscribes an
# inbox to the alerts topic, since the emulator sends no email.
emu-run: emu-only live-init ## Emulator: run ENV's task for real + alarm inbox (after make up)
	scripts/emulator-run-task.sh "$$($(TF_LIVE) output -raw cluster_name)" "$$($(TF_LIVE) output -raw service_name)" $(APP_PORT)
	scripts/emulator-alarm-inbox.sh setup "$$($(TF_LIVE) output -raw alerts_topic_arn)" $(PROJECT)-$(ENV)-alarm-inbox

# Failure injection: stop the database the app depends on. Readiness fails and
# every request becomes a 5xx, which the SLO alarm must catch; start brings it back.
chaos-db: emu-only ## Emulator: ACTION=stop|start ENV's database
	@case "$(ACTION)" in stop|start) ;; *) echo "!! ACTION must be stop or start"; exit 1;; esac
	docker $(ACTION) $(PROJECT)-$(ENV)-db >/dev/null && echo ">> $(PROJECT)-$(ENV)-db: $(ACTION)"

# The incident as a pass/fail test (CI runs it on every PR): traffic, stop the
# database, the SLO alarm must fire and notify, the app must recover.
# WAIT_FOR_OK=1 also waits for the alarm to clear (~5 more minutes).
emu-chaos-test: emu-only live-init ## Emulator: assert the SLO alarm fires when ENV's DB fails (after emu-run)
	scripts/emulator-chaos-test.sh "$$($(ENV_URL))" "$$($(TF_LIVE) output -raw slo_alarm_name)" \
	  $(PROJECT)-$(ENV)-alarm-inbox $(PROJECT)-$(ENV)-db \
	  "$$($(TF_LIVE) output -raw alb_metrics_namespace)" "$$($(TF_LIVE) output -raw alb_arn_suffix)"

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
	  $(PUSH_IMAGE) ; \
	fi

# PLAN_ARGS lets CI add flags (e.g. -no-color) while running the same target.
plan: live-init ## Show what `make up` would change (ENV=dev|prod)
	$(TF_LIVE) plan $(LIVE_VARS) $(PLAN_ARGS)

up: push-image deploy ## Laptop: build + push the image for HEAD, then deploy it (ENV=dev|prod)

# Deploy an image that is already in ECR. CI calls this directly (its build
# job pushed the image); APPLY_ARGS lets it add -auto-approve.
deploy: image-exists live-init ## Deploy IMAGE_TAG (must already be in ECR) to ENV
ifeq ($(EMULATOR),1)
	@# Emulator bug aws/aws-emulator#46: Terraform's removal of a new security
	@# group's default egress rule fails there, so the first apply stops with the
	@# groups tainted. Remove the rule the way the emulator matches it, untaint,
	@# apply again. Real AWS never takes this path.
	$(TF_LIVE) apply $(LIVE_VARS) $(APPLY_ARGS) || \
	  { scripts/emulator-sg-workaround.sh $(LIVE_DIR) && $(TF_LIVE) apply $(LIVE_VARS) $(APPLY_ARGS); }
else
	$(TF_LIVE) apply $(LIVE_VARS) $(APPLY_ARGS)
endif
	@echo ">> $(ENV) is live at $$($(TF_LIVE) output -raw public_url)   next: make smoke ENV=$(ENV)"

image-exists: aws-check
	@aws ecr describe-images --repository-name $(ECR_REPO) --image-ids imageTag=$(IMAGE_TAG) >/dev/null 2>&1 || \
	  { echo "!! $(ECR_REPO):$(IMAGE_TAG) is not in ECR (run make push-image, or let CI build it)"; exit 1; }

# terraform apply can "succeed" after ECS rolled back to the old image; this
# checks what is actually running (scripts/check-rollout.sh).
rollout-check: live-init ## Fail if ENV isn't running IMAGE_TAG on all tasks (e.g. rolled back)
	scripts/check-rollout.sh "$$($(TF_LIVE) output -raw cluster_name)" "$$($(TF_LIVE) output -raw service_name)" $(IMAGE_TAG)

smoke: live-init ## End-to-end test of a deployed environment
	scripts/smoke.sh "$$($(ENV_URL))"

# Steady synthetic traffic with a per-minute summary (MINUTES, RPS=5). On the
# emulator it also publishes the metrics the ALB would (scripts/traffic.sh).
traffic: live-init ## Synthetic traffic against ENV for MINUTES (default 10)
	scripts/traffic.sh "$$($(ENV_URL))" $(MINUTES) $(if $(TF_EMULATOR_VAR),"$$($(TF_LIVE) output -raw alb_metrics_namespace)" "$$($(TF_LIVE) output -raw alb_arn_suffix)",)

# The SLO alarm and its two burn-rate windows; on the emulator also the
# notifications the alerts topic sent (the emails people would have got).
alarms: live-init ## Show ENV's SLO alarm states (+ notifications on the emulator)
	@aws cloudwatch describe-alarms --alarm-names $(PROJECT)-$(ENV)-slo-burn-1h $(PROJECT)-$(ENV)-slo-burn-5m \
	  --query 'MetricAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp]' --output text
	@aws cloudwatch describe-alarms --alarm-types CompositeAlarm --alarm-names "$$($(TF_LIVE) output -raw slo_alarm_name)" \
	  --query 'CompositeAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp]' --output text
ifeq ($(EMULATOR),1)
	@echo ">> Notifications (alerts topic -> $(PROJECT)-$(ENV)-alarm-inbox):"
	@scripts/emulator-alarm-inbox.sh read $(PROJECT)-$(ENV)-alarm-inbox
endif

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

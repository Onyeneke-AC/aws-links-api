# Links API on AWS

A small URL shortener taken to production on AWS: containerised, provisioned with Terraform, deployed by a GitHub Actions pipeline with no AWS keys, observable through one SLO, and removed with one command.

- **App:** Node.js 26 + Fastify, Postgres 18. `POST /links` creates a short code, `GET /{code}` redirects.
- **AWS:** ECS Fargate (ARM64) behind an Application Load Balancer, RDS Postgres in isolated subnets, CloudWatch for metrics, logs, the SLO alarm and a dashboard.
- **Delivery:** every PR is linted, tested, scanned and `terraform plan`-ned; every merge to `main` builds one image and promotes it dev → approval → prod.

| Read | For |
|---|---|
| [DESIGN.md](DESIGN.md) | Architecture, decisions and rejected options, cost estimate, what's next |
| [RUNBOOK.md](RUNBOOK.md) | What to do when the `slo-at-risk` alarm fires |

## API

```sh
curl -s -X POST "$URL/links" -H 'content-type: application/json' -d '{"url":"https://example.com/some/long/path"}'
# 201 {"code":"aZ3kQ9x","target_url":"https://example.com/some/long/path","short_url":"http://…/aZ3kQ9x"}

curl -si "$URL/aZ3kQ9x"     # 302, Location: https://example.com/some/long/path
```

| Endpoint | Purpose |
|---|---|
| `POST /links` | Body `{"url": "http(s)://…"}` (max 2048 chars). Returns 201 with a 7-character code; 400 if the URL isn't http/https |
| `GET /{code}` | 302 to the target (never cached), 404 if unknown |
| `GET /healthz` | Liveness: the process is up (container health check) |
| `GET /readyz` | Readiness: the database answers (load balancer health check); 503 if not |
| `GET /metrics` | Prometheus metrics: request duration by route, plus Node process metrics (CPU, memory, event-loop lag). Blocked (404) at the load balancer in AWS |

Logs are one JSON line per request (method, route, status, duration, request ID); target URLs are never logged.

## Run it locally

Needs Node 26 (`.nvmrc`) and Docker.

```sh
npm ci
make test                                   # starts Postgres in Docker, runs 32 unit + integration tests
cp .env.example .env
node --env-file=.env src/server.js          # http://localhost:3000
scripts/smoke.sh http://localhost:3000      # the same end-to-end check CI runs after each deploy
make db-down                                # stop Postgres and delete its data
```

## Run it on AWS

**Needs:** an AWS account and a logged-in AWS CLI profile with admin rights, Terraform 1.17, Docker (with `buildx`), GNU Make, and the GitHub CLI if you want the pipeline.

```sh
export AWS_PROFILE=<your-profile> AWS_REGION=eu-west-1
make aws-check              # shows which account you're about to change

make bootstrap              # once: state bucket, ECR, GitHub OIDC provider, CI roles
make up ENV=dev             # build + push the image for HEAD, create dev (~15 min, mostly RDS)
make smoke ENV=dev          # end-to-end test through the public URL

make teardown               # delete prod, dev and bootstrap; asks you to type the account ID
```

Everything is derived at run time (the account ID names the state bucket; the GitHub repo the CI roles trust is detected from your clone), so there's nothing to edit first. Bootstrapping in an account from a clone without GitHub access creates no CI roles at all.

**Brand-new AWS accounts:** AWS may refuse to run Fargate tasks until the account is verified. The ECS service then reports "unable to place a task because your account is currently blocked" and `make up` fails at the ECS service after the network, database and load balancer are already created. It isn't a code problem: open a free support case (Account and billing) asking for verification, run `make destroy ENV=dev` meanwhile to stop paying for the half-built environment, and re-run `make up` once AWS confirms. Established accounts aren't affected.

### Without an AWS account: the AWS Emulator

[AWS Emulator](https://github.com/aws/aws-emulator) is AWS's own local emulator of the AWS APIs. The same Terraform and the same targets run against it with `EMULATOR=1` (Docker only, no AWS account, about 5 minutes for the full cycle):

```sh
make emu-up                      # starts it at https://127.0.0.1:9297
make bootstrap EMULATOR=1
make up ENV=dev EMULATOR=1       # image + all of dev: VPC, RDS, ALB, ECS, alarms, dashboard
make rollout-check ENV=dev EMULATOR=1
make emu-run ENV=dev EMULATOR=1  # run the task definition for real + an inbox for the alarm
make smoke ENV=dev EMULATOR=1

# the SLO alarm, end to end (two terminals):
make traffic ENV=dev EMULATOR=1 MINUTES=13          # synthetic traffic, per-minute error rate
make chaos-db ENV=dev EMULATOR=1 ACTION=stop        # after ~3 min: every request now fails
make alarms ENV=dev EMULATOR=1                      # burn-rate alarms, composite, notifications
make chaos-db ENV=dev EMULATOR=1 ACTION=start       # recover; the composite clears ~5 min later
# or the same as a pass/fail test (what CI runs on every PR; WAIT_FOR_OK=1 also waits for the clear):
make emu-chaos-test ENV=dev EMULATOR=1

make teardown EMULATOR=1         # confirm with 000000000000
make emu-down
```

With `EMULATOR=1` the Makefile points every AWS call at the emulator and drops any real AWS credentials from the shell, and Terraform refuses any account but the emulator's.

**What runs for real and what stands in:** the emulator records ECS tasks without starting containers, its RDS endpoint isn't a full Postgres, its load balancer doesn't forward to targets and publishes no request metrics, and it sends no email. So `emu-run` plays the ECS agent: it runs the image named in the service's task definition (pulled from the emulator's ECR) with that definition's settings and the credentials RDS put in Secrets Manager, against Postgres 18 standing in for RDS, published on `127.0.0.1:8080` in place of the load balancer. `traffic` measures every response the way the load balancer would and publishes the same metric names, which the unchanged SLO alarms read from a separate namespace (`AWS/` is reserved for AWS). The alerts topic delivers to an SQS inbox instead of email. The emulator doesn't enforce IAM, security groups or private subnets either: those are only proven on AWS. It has three known differences from AWS, worked around only in this mode: the security-group default-egress bug ([aws/aws-emulator#46](https://github.com/aws/aws-emulator/issues/46), `scripts/emulator-sg-workaround.sh`), Postgres 18's `log_connections` still validated as a boolean (the emulator gets `1`), and images pushed through the ECR API because its registry only serves pulls (`scripts/ecr-api-push.sh`).

`make help` lists every target. The ones you'll use:

| Target | Does |
|---|---|
| `make up ENV=dev\|prod` | Build and push the image for the current commit, then `terraform apply` |
| `make plan ENV=…` | What `up` would change |
| `make smoke ENV=…` | End-to-end test of a deployed environment |
| `make traffic ENV=… MINUTES=10` | Steady synthetic traffic, with the error rate each minute |
| `make alarms ENV=…` | State of the SLO alarm and its two burn-rate windows |
| `make destroy ENV=…` | Delete one environment |
| `make teardown` | Delete everything this project created |

Optional: `export TF_VAR_alarm_email=you@example.com` before `make up` to get the SLO alarm by email (confirm the subscription email AWS sends).

## The pipeline

```
pull request ──► pr.yml:  app (lint, audit, tests on Postgres) · image (ARM64 build, size, Trivy)
                          · terraform (fmt, validate, plan dev + prod → PR comment)
                          · emulator (bootstrap, deploy dev, smoke, DB chaos → SLO alarm must fire,
                            teardown: all on the local AWS Emulator, no AWS account)
merge to main ─► main.yml: build once → ECR :<sha> → deploy dev → approval → deploy prod (same image)
                           each deploy: terraform apply → check the new image really runs → smoke test
```

- **No AWS keys.** Each job exchanges GitHub's OIDC token for one-hour credentials. Pull requests get a read-only role; `main` can only push images; only the `dev` / `prod` GitHub environments, from `main`, can apply to that environment.
- **Branch protection** requires the three PR checks before anything reaches `main`.
- **Approval** is a GitHub issue the pipeline opens; comment `approve` to ship to prod.
- **Rollback** is automatic (ECS circuit breaker, plus the SLO alarm during deploys), and the pipeline fails if it happened, so prod never gets a build that rolled back in dev. Manual rollback: see [RUNBOOK.md](RUNBOOK.md#3-fix).

One-time GitHub setup after `make bootstrap` (role ARNs are in `terraform -chdir=infra/bootstrap output ci_role_arns`):

```sh
gh variable set AWS_REGION --body eu-west-1
gh variable set AWS_PLAN_ROLE_ARN     --body <plan role ARN>
gh variable set AWS_ECR_PUSH_ROLE_ARN --body <ecr_push role ARN>
# create environments dev and prod (Settings → Environments), each limited to the main branch, then:
gh variable set AWS_APPLY_ROLE_ARN --env dev  --body <apply_dev role ARN>
gh variable set AWS_APPLY_ROLE_ARN --env prod --body <apply_prod role ARN>
gh secret set ALARM_EMAIL --env prod        # optional, prompts for the address
gh variable set DEPLOYS_ENABLED --body true # deploys are skipped until this is set
```

## Repository layout

```
src/, test/              the app and its tests
Dockerfile               multi-stage, Alpine + Node 26, non-root, 120 MB
compose.yaml             Postgres for local development
infra/bootstrap/         state bucket, ECR, GitHub OIDC provider, CI roles + permissions boundary
infra/modules/           network · database · edge (ALB) · service (ECS) · observability
infra/live/              the one root stack; envs/dev.tfvars, envs/prod.tfvars
scripts/                 smoke.sh · image-checks.sh (size + Trivy) · check-rollout.sh
.github/workflows/       pr.yml · main.yml · deploy.yml (reusable, per environment)
Makefile                 every command above; CI calls the same targets
```

## Known limitations

The main ones (full list and reasoning in [DESIGN.md](DESIGN.md)):

- **HTTP only, no TLS.** CloudFront was designed in but AWS blocks it on unverified accounts; the fix is ready (git history `f66d06f`).
- dev and prod share one AWS account (separated by naming, state and IAM); separate accounts are the next step.
- Single-AZ database and one NAT gateway per environment, for cost.

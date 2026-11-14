# Design: Links API on AWS

A URL shortener (`POST /links`, `GET /{code}`) on ECS Fargate and RDS Postgres, provisioned with Terraform, shipped by GitHub Actions without AWS keys. This page explains the choices; [README](README.md) says how to run it, [RUNBOOK](RUNBOOK.md) what to do when the alarm fires.

## Architecture

```
                     internet (HTTP :80)
                            │
   ┌─ VPC 10.x.0.0/16, 2 AZs (dev 10.10, prod 10.20) ─────────────────────┐
   │  public    10.x.0-1.0/24     ALB (/metrics → 404)     NAT gateway    │
   │                                   │ :3000                  ▲         │
   │                                   ▼                        │ :443    │
   │  private   10.x.10-11.0/24   ECS Fargate tasks ────────────┘         │
   │                              (ARM64; to ECR, Secrets Manager, logs)  │
   │                                   │ :5432, TLS verified              │
   │                                   ▼                                  │
   │  database  10.x.20-21.0/24   RDS Postgres 18 (no route out at all)   │
   └──────────────────────────────────────────────────────────────────────┘
   Health checks: ALB → /readyz (pings the DB); container → /healthz (process only)
   Secrets Manager: DB password (created and rotated by RDS) → injected at task start
   CloudWatch: ALB/ECS/RDS metrics, JSON logs, SLO alarm → SNS email, dashboard
```

Security groups chain by reference, not by IP: internet → ALB :80 → app :3000 → DB :5432. The database has no egress rule and its subnets have no route out, so even a security-group mistake can't give it a path to the internet.

## Key decisions

| Area | Decision | Why | Rejected / cost |
|---|---|---|---|
| Compute | ECS Fargate, ARM64 (Graviton), 0.25 vCPU / 0.5 GB | No servers or cluster to run; ARM is about 20% cheaper and Macs build it natively | EKS: control-plane cost and upgrades for one service. Lambda: less control over networking and connection pooling |
| Database | RDS Postgres 18, db.t4g.micro, single-AZ, encrypted, own subnets | SQL suits a product team; RDS handles backups, patching, and the password | Multi-AZ: doubles DB cost; single-AZ means minutes of downtime on failure (accepted for this size). DynamoDB: leaner for key-value, but no SQL |
| Edge | Public ALB on plain HTTP | Designed as CloudFront (HTTPS on `*.cloudfront.net`) in front of a locked-down ALB, but AWS blocks CloudFront on unverified accounts. The design is in git history (`f66d06f`) | **No TLS** is the biggest gap: links and redirects travel in clear text. Fix: CloudFront once verified, or a domain + ACM certificate |
| Secrets | `manage_master_user_password`: RDS creates and rotates the password in Secrets Manager; ECS injects it at task start | The password is never in code, the image, CI logs or Terraform state | Terraform `random_password` ends up in state. App uses the master user (next: a least-privilege app user or IAM auth) |
| Health | ALB checks `/readyz` (pings the DB); the container checks `/healthz` (process only) | A deploy whose tasks can't reach the DB never takes traffic, so the circuit breaker rolls it back | Least-sure decision: in a DB outage every target goes unhealthy and ECS cycles tasks. Alternative: readiness without the DB, alarm on DB errors instead |
| Image | Multi-stage, Alpine + Alpine's Node 26, non-root (uid 10001), read-only root filesystem, 120 MB | The official Node 26 binary alone is 148 MB, which breaks the 150 MB budget | Node patch version floats within 26.x on rebuild; the immutable SHA-tagged image is what gets promoted |
| Terraform | `bootstrap` (state bucket, ECR, OIDC, CI roles) + 5 modules + one root `infra/live` for both environments (`envs/<env>.tfvars`, state key `live/<env>/`) | No copy-pasted environment folders; the bucket name comes from the account ID, so the repo runs in any account unchanged | Workspaces: hidden state switching. DynamoDB locks: replaced by S3-native locking (Terraform 1.10+) |
| Environments | dev and prod in one account, separate VPCs, separated by name prefix, state key and IAM | One account keeps setup small | Separate accounts per environment is the stronger boundary (next step) |
| Delivery | Build once, tag with the commit SHA (ECR tags immutable), deploy = `terraform apply -var image_tag=<sha>`, dev → approval → prod with the same image | Prod runs the exact bytes dev tested; Terraform stays the single source of truth for the task definition | A separate ECS deploy tool would change the task definition behind Terraform's back |
| CI access | GitHub OIDC, 4 roles: plan (PRs, read-only), ecr-push (main), apply-dev / apply-prod (GitHub environment + `main`) | No long-lived keys. Apply roles touch only `links-<env>-*`, write only their own state, and can create IAM roles only with a permissions boundary (no privilege escalation) | Access keys in GitHub secrets. EC2 networking needs `*` (VPC resources have random IDs): documented in the policy |
| Rollback | ECS circuit breaker + an SLO alarm watched during deploys; the pipeline checks which image is really running | A rollback leaves the service "steady" on the old image, so a successful `apply` alone proves nothing | |
| Observability | SLO on ALB metrics: 99.5% non-5xx over 7 days; one alarm on a 14.4× burn rate over 1 h **and** 5 min → email | The ALB sees what users see, including its own 503 when no task is healthy | CPU alarms (not user pain). Scraping the app's `/metrics` (ADOT or Managed Prometheus: more cost and parts) |

### App behaviour

| Decision | Why | Cost / rejected option |
|---|---|---|
| **Same URL → new code every time** (no de-duplication) | Links stay independent (separate analytics and lifecycle). No leak of whether a URL was shortened before (with dedup, anyone could probe if a private URL had been shared). No extra index on `target_url`, no race between two requests for the same URL. | Duplicate rows for popular URLs (negligible). A retried POST creates a second code. The fix is an `Idempotency-Key` header, not dedup (next week). Rejected: unique index on `sha256(target_url)` + "insert or return existing", which brings the privacy leak with it. |
| 7-character random base62 codes | 3.5 trillion combinations: unguessable, so links can't be enumerated; collisions are retried | Sequential IDs: short but enumerable |
| 302 redirects, never cached | Links can be changed or removed, and every click reaches our metrics | 301: browsers cache it forever |
| Schema created at startup, under a Postgres advisory lock | Two tasks starting together can't race; no extra migration step | A real migration tool or one-off migration task as the schema grows |

## Cost estimate

On-demand prices for eu-west-1 from the AWS Price List API, per month (730 hours), running 24/7:

| Item | dev | prod | Notes |
|---|---|---|---|
| NAT gateway | $35.04 | $35.04 | $0.048/h, plus $0.048/GB (image pulls go via the free S3 endpoint) |
| Application Load Balancer | $18.40 | $18.40 | $0.0252/h, plus about $1 of capacity units at low traffic |
| RDS db.t4g.micro + 20 GB gp3 | $14.95 | $14.95 | $0.017/h + $0.127/GB; backups up to DB size are free |
| Fargate ARM tasks | $7.21 | $14.42 | 1 task in dev, 2 in prod (one per AZ) |
| Public IPv4 (NAT + 2 for the ALB) | $10.95 | $10.95 | $0.005/h each |
| Secrets Manager, CloudWatch, logs, ECR | ~$3 | ~$3 | Alarms ~$1.10, secret $0.40, small log volume |
| **Total** | **~$90** | **~$97** | **~$187/month for both** |

**One cut:** dev doesn't need to run 24/7. It's fully reproducible (`make up ENV=dev`, about 15 minutes, mostly RDS), so tearing it down outside working hours saves about $65 of its $90. Moving NAT traffic to VPC interface endpoints would *add* cost here (4 endpoints × 2 AZs ≈ $64/month) and only pays off at higher traffic.

**What production-grade resilience would add:** Multi-AZ RDS +$15, a NAT gateway per AZ +$39, about $54/month for prod.

## What I would do with another week

1. **TLS:** CloudFront in front (restore `f66d06f`) once the account is verified, or a domain with an ACM certificate and HTTP→HTTPS redirect.
2. **Separate AWS accounts** for dev and prod, with the CI roles per account.
3. **Database:** IAM database authentication. The app connects as a `links_app` user (only `SELECT`/`INSERT` on `links`) with a 15-minute token signed by its ECS task role, instead of the master user's password. That fixes two gaps at once: the app is no longer the master user, and with no password there's nothing to rotate, so the manual redeploy after RDS rotates the secret (runbook step B) disappears. Needs one SQL step (`CREATE USER links_app; GRANT rds_iam TO links_app;`), a task role with `rds-db:connect`, and the token signer in the app. Plus Multi-AZ for prod.
4. **`Idempotency-Key` header** on `POST /links`, so client retries don't create duplicate links.
5. **Observability:** a slow-burn alarm (6× over 6 h + 30 min, ticket instead of page), a synthetic check so a broken idle service is noticed, and the app's `/metrics` collected (ADOT sidecar).
6. **Delivery:** a migration tool, autoscaling on request count per task, a WAF with rate limiting on `POST /links`.

# Runbook: `links-<env>-slo-at-risk`

The one alarm that notifies people. If you got its email, start here.

## What it means

Users are getting errors fast enough to threaten the SLO.

- **SLO:** 99.5% of requests succeed (no 5xx) over a rolling 7 days. The 0.5% that may fail is the *error budget*.
- **The alarm fires** when more than **7.2%** of requests fail over **both** the last hour **and** the last 5 minutes. That is 14.4 times the allowed rate: at this pace the week's budget is gone in about 12 hours.
- **"Failed"** means a 5xx from the app *or* from the load balancer (502 task crashed, 503 no healthy task, 504 timeout). 4xx (bad requests) never count.
- **It clears** about 5 minutes after the error rate drops back, and you get an "OK" email.

It doesn't fire on very low traffic (fewer than 10 requests in 5 minutes): a broken but idle service can stay silent. `make smoke` is the check for that.

## Setup (once per shell)

```sh
export AWS_PROFILE=<your profile> AWS_REGION=eu-west-1
E=prod                      # or dev: the environment named in the alarm
C=links-$E S=links-$E-api   # ECS cluster and service
```

## 1. Confirm and size it (2 minutes)

Open the dashboard: CloudWatch → Dashboards → **`links-<env>`** (or `terraform -chdir=infra/live output -raw dashboard_url` after `make live-init ENV=$E`).

| Widget | Question |
|---|---|
| Error rate (5xx %) | How high, since when? Above the red line = alarm level. |
| Request rate | Did traffic spike (overload) or drop to zero (users gone, or a total outage)? |
| Latency p95 | Slow before failing? Points at the database or overload. |
| Tasks passing /readyz | Fewer healthy tasks than desired = tasks failing. **Zero = total outage.** |

Is it the whole service or some requests?

```sh
make smoke ENV=$E     # end-to-end: readyz, create a link, follow it
```

## 2. Find the cause

Work down the list; most incidents stop at the first match.

### a) Was there a deploy just before?

```sh
aws ecs describe-services --cluster $C --services $S \
  --query 'services[0].{deployments:deployments[].[status,rolloutState,taskDefinition,runningCount,createdAt],events:events[0:8].message}'
gh run list --workflow main.yml --limit 5      # what the pipeline shipped, and when
```

- A deployment with `rolloutState` **IN_PROGRESS** or a new one in the last hour, and errors starting at the same time: **suspect the deploy, go to fix A.**
- `FAILED` + a newer deployment of the *old* task definition: ECS already rolled back by itself (new tasks failed health checks, or `links-<env>-slo-burn-5m` fired during the deploy). Errors should be falling; confirm on the dashboard. The pipeline run for that commit will have failed at "Check the new image is really running".

### b) Are tasks healthy?

```sh
TG=$(aws elbv2 describe-target-groups --names links-$E-app --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn $TG \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output table

# Why did tasks stop? (crash on start, failed health check, out of memory)
aws ecs describe-tasks --cluster $C \
  --tasks $(aws ecs list-tasks --cluster $C --desired-status STOPPED --query 'taskArns[0:5]' --output text) \
  --query 'tasks[].[stoppedAt,stopCode,stoppedReason,containers[0].exitCode]' --output table
```

| You see | Likely cause | Go to |
|---|---|---|
| `stoppedReason` mentions `ResourceInitializationError` / secret / ECR pull | Execution role or secret problem; usually after a change | A or B |
| `exitCode 1` soon after start | App fails at boot (logs say `startup failed`) | logs, then A or B |
| `exitCode 137` / `OutOfMemoryError` | Out of memory | E |
| Targets `unhealthy`, reason `Target.ResponseCodeMismatch` | `/readyz` returns 503: the database is unreachable | c) |

### c) Is the database OK?

```sh
aws logs tail /ecs/$S --since 15m --filter-pattern '"readiness check failed"'   # DB unreachable from tasks
aws rds describe-db-instances --db-instance-identifier links-$E-db \
  --query 'DBInstances[0].[DBInstanceStatus,MasterUserSecret.SecretStatus]'
aws rds describe-events --source-type db-instance --source-identifier links-$E-db --duration 120 \
  --query 'Events[].[Date,Message]' --output table
```

- Status not `available` (`rebooting`, `modifying`, `storage-full`, …): RDS-side, **fix C**.
- Logs show `password authentication failed` and the secret was rotated recently: **fix B**.
- RDS CPU near 100% or connections climbing on the dashboard: overload, **fix E** (or C for storage).

### d) What are the errors?

```sh
# App errors and 5xx responses (structured JSON logs; target URLs are never logged)
aws logs tail /ecs/$S --since 15m --format short \
  --filter-pattern '{ ($.statusCode >= 500) || ($.level >= 50) }'
```

The `reqId` in a log line matches the ALB's `X-Amzn-Trace-Id`, so one failing request can be followed end to end. The dashboard's bottom widget shows the same lines.

## 3. Fix

**A. Bad deploy: roll back.** Every image is in ECR under its commit SHA (tags are immutable), so rolling back is redeploying the previous SHA.

- Normal path: `git revert` the bad merge in a PR. Checks pass, merge, the pipeline deploys dev then prod (with approval).
- Emergency, faster (from a laptop with admin access). The tag must be a **full 40-character SHA that exists in ECR**: not every commit has an image (docs-only merges and PR branch commits don't), so pick from ECR, not from `git log`:
  ```sh
  # What's running now (the bad one)
  aws ecs describe-task-definition --task-definition \
    "$(aws ecs describe-services --cluster $C --services $S --query 'services[0].taskDefinition' --output text)" \
    --query 'taskDefinition.containerDefinitions[0].image' --output text

  # Deployable images, newest first (one image can carry several SHA tags if the build was identical)
  aws ecr describe-images --repository-name links-api \
    --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0:5].[imagePushedAt,join(`, `,imageTags)]' --output table

  # Pick the newest one OLDER than the bad one, then:
  make deploy ENV=$E IMAGE_TAG=<full-sha>          # same terraform, older image
  make rollout-check ENV=$E IMAGE_TAG=<full-sha>
  ```
  `gh run list --workflow main.yml --status success` shows which SHAs made it all the way through the pipeline. Then revert in git anyway, or the next pipeline run redeploys the bad commit.

**B. Database password rotated, tasks still use the old one.** RDS rotates the managed secret every 7 days; running tasks read it only at start.
```sh
aws ecs update-service --cluster $C --service $S --force-new-deployment
```
New tasks fetch the current password; the ALB drains the old ones.

**C. Database itself.** If RDS is rebooting or in maintenance, wait for `available` (single-AZ: minutes of downtime is a known trade-off, see DESIGN.md). If storage is full, autoscaling should have grown it up to 50 GB: raise `max_allocated_storage_gb` in the database module and apply.

**D. Nothing changed, tasks healthy, errors persist.** Look at the error messages (2d). Restarting buys time while you read them: `--force-new-deployment` as in B.

**E. Overload (traffic spike, CPU/memory at the limit, DB connections maxed).** Short-term:
```sh
aws ecs update-service --cluster $C --service $S --desired-count 4
```
Then make it permanent in `infra/live/envs/$E.tfvars` (`desired_count`) through a PR; otherwise the next deploy sets it back.

## 4. Confirm recovery

1. Dashboard: error rate back under 0.5%, healthy tasks = desired.
2. `make smoke ENV=$E` passes.
3. The alarm's **OK** email arrives (about 5 minutes after the errors stop).

## 5. Afterwards

- Write down: start/end time, cause, what fixed it, and how much error budget it used (SLO widget, time range 1w, "Error budget used %").
- Anything manual (desired count, `--force-new-deployment`, laptop deploy) is drift from Terraform or git: make it a PR, or revert it.
- If the budget is mostly spent, prefer reliability work over new features until it recovers.

## Reference

| Thing | Name |
|---|---|
| Alarm (notifies) / its two inputs | `links-<env>-slo-at-risk` / `links-<env>-slo-burn-1h`, `links-<env>-slo-burn-5m` |
| Dashboard | `links-<env>` |
| ECS cluster / service | `links-<env>` / `links-<env>-api` |
| App logs | `/ecs/links-<env>-api` |
| Database / its logs | `links-<env>-db` / `/aws/rds/instance/links-<env>-db/postgresql` |
| Load balancer / target group | `links-<env>-alb` / `links-<env>-app` |
| Alert topic | `links-<env>-alerts` (SNS, email) |

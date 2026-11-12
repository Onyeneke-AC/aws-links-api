# Design — Links API on AWS

<!-- Max 2 pages. Sections marked TODO are filled in as the build progresses. -->

## Architecture
TODO: diagram (CloudFront → ALB → ECS Fargate in private subnets → RDS Postgres).

## Key decisions and rejected options
TODO: compute, database, edge/TLS, secrets, CI/CD, Terraform layout.

### App behaviour
| Decision | Why | Cost / rejected option |
|---|---|---|
| **Same URL → new code every time** (no de-duplication) | Links stay independent (separate analytics and lifecycle). No leak of whether a URL was shortened before (with dedup, anyone could probe if a private URL had been shared). No extra index on `target_url`, no race between two requests for the same URL. | Duplicate rows for popular URLs (negligible). A retried POST creates a second code. The fix is an `Idempotency-Key` header, not dedup (next week). Rejected: unique index on `sha256(target_url)` + "insert or return existing", which brings the privacy leak with it. |

## Cost estimate
TODO.

## What I would do with another week
- `Idempotency-Key` header on `POST /links` so client retries don't create duplicate links.

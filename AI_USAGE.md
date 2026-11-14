# How I used AI

I built this with **Claude Code** (Anthropic's coding agent) in VS Code, as a pair: it drafted most of the code and documents, explained each piece, and ran read-only checks; I made the decisions, reviewed every change, ran everything that changed AWS, and committed and merged it all myself.

## Division of work

| I did | Claude did |
|---|---|
| Chose the architecture and made the calls on trade-offs (e.g. dropping CloudFront when AWS blocked it) | Drafted the app, tests, Dockerfile, Terraform modules, workflows, scripts and these docs |
| Reviewed each change before committing; asked for explanations until I could defend every line | Explained each piece and proposed small, separate commits |
| Ran every command that changes AWS: `make bootstrap`, `make up`, `make destroy`, and set up GitHub (variables, environments, branch protection) | Ran read-only checks: tests, local container runs, `terraform plan` with a throwaway backend, IAM Access Analyzer, the IAM policy simulator, CloudTrail lookups, the AWS Price List API |
| Opened every PR and merged after the checks passed | Diagnosed failures from logs, CloudTrail and AWS APIs |

Ground rules I set:
- **AI never applies to AWS.** Early on it tried to run `make bootstrap` itself; the permission system blocked it, and from then on it only ran read-only commands.
- **No secrets in prompts.** AWS access came from my short-lived SSO session; there are no access keys anywhere in this project.
- **Small commits, each one explained**, and a running log of real AI mistakes (below), written when they happened.

## How I checked its work

Nothing was accepted because it looked right. Each layer has its own check:

| Layer | Check |
|---|---|
| App | 32 unit and integration tests against real Postgres, lint, `npm audit`, manual runs with `curl` and a browser |
| Image | Measured, not assumed: `docker history` for size (120 MB), Trivy for vulnerabilities, a local run with a read-only filesystem and non-root user |
| Terraform | `fmt`, `validate`, then `plan` against the real account before any apply; engine-specific values checked against the AWS API |
| IAM | Access Analyzer (0 errors) and 15 policy-simulator cases (e.g. dev role allowed on dev, denied on prod; can't create a role without the permissions boundary) |
| Workflows | `actionlint`, `shellcheck`, then real runs on real PRs |
| Everything | The first real run. Two of the mistakes below were only visible there |

## Where I steered it

Some of the better parts of the design came from questioning a proposal:

- **One VPC or two?** I asked whether dev and prod should have separate VPCs; they now do, with non-overlapping ranges.
- **Database in its own subnets.** I asked whether the database shared the app's subnets. It did, protected only by security groups; it now sits in subnets with no route out at all.
- **Would a reviewer have to edit anything?** I asked this about the hard-coded GitHub repo in the CI trust policies. It now detects the repo from the clone, and creates no CI roles when there isn't one, so bootstrapping in someone else's account never grants a GitHub repo access to it.
- **What would I actually type to roll back?** Asking this exposed mistake 8.

## AI mistakes

Real mistakes, in the order they happened. None affected users or left anything broken; two (5 and 6) did happen against real AWS resources.

| # | What Claude got wrong | How it was caught | Fix |
|---|---|---|---|
| 1 | Recommended Node 24 as the current LTS; Node 26 was Active LTS | My tool check showed Node 26 installed; the release schedule confirmed it | Standardised on Node 26 |
| 2 | Used a Fastify option deprecated in 5.12 (`disableRequestLogging`) | Deprecation warning in the first test run (tests passed) | Read the installed package's docs; switched to `logController` |
| 3 | Claimed deleting npm in a later Docker layer shrinks the image (layers are additive), and assumed the official Node 26 image fits 150 MB (its binary alone is 148 MB) | Measuring the built image | Alpine base with Alpine's Node package: 120 MB |
| 4 | Set Postgres `log_connections = "1"`; in Postgres 18 it's a list, so RDS would have rejected it | Checked against `aws rds describe-engine-default-parameters` before any apply (`terraform validate` can't catch it) | `receipt,authentication,authorization` |
| 5 | The destroy step deleted the state file when `terraform state list` printed nothing, without checking whether it had failed. It did fail, because Claude had put a temporary file in the folder I was running Terraform in | My `make destroy` output. Harmless that time: everything was already destroyed, and the bucket is versioned | Stop if `state list` fails; Claude no longer touches a folder I'm working in |
| 6 | Wrote the CI trust policies with GitHub's old OIDC subject format (`repo:owner/name`); GitHub now sends `repo:owner@id/name@id`, so the first PR couldn't log in to AWS | Failed PR check; CloudTrail showed the exact subject GitHub sent (static checks can't know it) | ID-based subject, detected automatically. Safer too: a recreated repo with the same name can't assume the roles |
| 7 | Measured image size with `docker save`, assuming uncompressed output; Docker Desktop's store exports compressed layers (41 MB instead of 120) | Testing the script locally before committing | Sum of `docker history` layer sizes |
| 8 | The runbook said to pick a rollback version from `git log`: short SHAs, and many commits have no image (docs-only merges, PR branches) | I asked what exactly to pass to the command | Runbook lists deployable images from ECR, full SHAs only |

## What I took from it

- **AI knowledge lags fast-moving tools** (Node releases, Fastify minors, Postgres 18, GitHub's token format). Warnings, real API responses and real runs are the source of truth, not the model's memory.
- **"It validates" isn't "it works".** Four of the eight were invisible to static checks and only showed up against real APIs or real runs, which is why every change went through a plan, a PR run, or a measurement first.
- **Asking "what exactly would I type?"** catches instructions that only sound right.
- Used this way, it made me faster *and* made me understand the system better: I had to be able to explain every line before it was committed.

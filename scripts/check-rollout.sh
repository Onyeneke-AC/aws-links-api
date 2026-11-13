#!/usr/bin/env bash
# Did the deployment actually land? `terraform apply` succeeding is not proof:
# if new tasks fail, the ECS circuit breaker rolls back to the previous task
# definition, and the service ends up "steady" again, just on the OLD image.
# So check what is really running.
#
# Usage: scripts/check-rollout.sh <cluster> <service> <expected image tag>
# Exit 0 = the expected image is live on every task; 1 = rolled back / failed.
set -euo pipefail

cluster="${1:?usage: check-rollout.sh <cluster> <service> <image_tag>}"
service="${2:?}"
tag="${3:?}"
fail() { echo "FAIL: $*" >&2; exit 1; }

# The PRIMARY deployment is the one ECS is converging to (after a rollback,
# that's a new deployment of the old task definition).
for _ in $(seq 1 30); do
  # Backticks are JMESPath literals (AWS CLI query), not shell: keep single quotes.
  # shellcheck disable=SC2016
  read -r state taskdef running desired < <(aws ecs describe-services \
    --cluster "$cluster" --services "$service" \
    --query 'services[0].deployments[?status==`PRIMARY`]|[0].[rolloutState,taskDefinition,runningCount,desiredCount]' \
    --output text)
  [ "$state" != "IN_PROGRESS" ] && break
  echo "rollout in progress ($running/$desired tasks), waiting..."
  sleep 10
done

image=$(aws ecs describe-task-definition --task-definition "$taskdef" \
  --query 'taskDefinition.containerDefinitions[0].image' --output text)

echo "PRIMARY deployment: state=$state tasks=$running/$desired image=$image"

[[ "$image" == *":$tag" ]] || fail "service runs $image, expected tag $tag: the deployment was rolled back"
[ "$state" = "COMPLETED" ] || fail "rollout state is $state"
[ "$running" = "$desired" ] || fail "$running of $desired tasks running"
echo "Rollout OK: $tag is live on $running/$desired tasks"

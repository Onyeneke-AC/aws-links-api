#!/usr/bin/env bash
# AWS Emulator only: run the ECS service's task for real, as the ECS agent would.
#
# The emulator records ECS tasks as RUNNING but starts no containers, its RDS
# endpoint isn't a full Postgres, and its load balancer doesn't forward to
# targets. This script plays the parts that are missing, driven by what
# Terraform registered in the emulator:
#   1. reads the service's current task definition (image, env, secrets, flags)
#   2. pulls that image from the emulator's ECR
#   3. resolves the secrets from Secrets Manager (the password RDS generated)
#   4. starts Postgres 18 in place of RDS, with those credentials
#   5. starts the app container with the task definition's settings, published
#      on 127.0.0.1:<port> in place of the load balancer
# Only the database address/TLS mode and the public URL are overridden (and
# printed); everything else comes from the task definition.
#
# usage: scripts/emulator-run-task.sh <cluster> <service> <host port>
set -euo pipefail

cluster=${1:?cluster} service=${2:?service} port=${3:?host port}
[ "$(aws sts get-caller-identity --query Account --output text)" = 000000000000 ] ||
  { echo "!! Not the AWS Emulator (account 000000000000): refusing" >&2; exit 1; }

net="$cluster-emu" db="$cluster-db" app="$cluster-api" label="links-emulator=$cluster"

taskdef=$(aws ecs describe-services --cluster "$cluster" --services "$service" \
  --query 'services[0].taskDefinition' --output text)
container=$(aws ecs describe-task-definition --task-definition "$taskdef" \
  --query 'taskDefinition.containerDefinitions[0]' --output json)
image=$(jq -r .image <<<"$container")
echo ">> Task definition $taskdef"
echo "   image $image"

# 2. Pull from the emulator's registry (it serves pulls; pushes went through the API).
aws ecr get-login-password | docker login --username AWS --password-stdin "${image%%/*}" >/dev/null
docker pull -q "$image" >/dev/null

# 3. Environment = the task definition's plain values + its secrets, resolved
# the way the ECS agent does ("<secret arn>:<json key>::"). Written to a
# private temp file for `docker run --env-file`, never printed.
envfile=$(mktemp)
chmod 600 "$envfile"
trap 'rm -f "$envfile"' EXIT
jq -r '.environment[] | "\(.name)=\(.value)"' <<<"$container" >"$envfile"
while read -r name value_from; do
  ref=${value_from%::}        # <secret arn>:<json key>
  key=${ref##*:} arn=${ref%:*}
  aws secretsmanager get-secret-value --secret-id "$arn" --query SecretString --output text |
    jq -r --arg n "$name" --arg k "$key" '"\($n)=\(.[$k])"' >>"$envfile"
  echo "   secret $name <- Secrets Manager ($key)"
done < <(jq -r '.secrets[] | "\(.name) \(.valueFrom)"' <<<"$container")
get() { sed -n "s/^$1=//p" "$envfile" | tail -1; }

# Start clean: a previous run's containers and data are replaced.
docker rm -f "$app" "$db" >/dev/null 2>&1 || true
docker volume rm "$db-data" >/dev/null 2>&1 || true
docker network inspect "$net" >/dev/null 2>&1 || docker network create --label "$label" "$net" >/dev/null
docker volume create --label "$label" "$db-data" >/dev/null

# 4. Postgres 18 in place of RDS, with the credentials RDS created. Its data
# is on a volume, so like RDS it survives a stop/start (make chaos-db).
docker run -d --name "$db" --network "$net" --label "$label" \
  -e POSTGRES_USER="$(get PGUSER)" -e POSTGRES_PASSWORD="$(get PGPASSWORD)" -e POSTGRES_DB="$(get PGDATABASE)" \
  -v "$db-data:/var/lib/postgresql" --health-cmd "pg_isready -U $(get PGUSER)" --health-interval 2s \
  postgres:18.6-alpine >/dev/null
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$db")" = healthy ] && break
  sleep 1
done
echo ">> Postgres 18 ($db) in place of RDS"

# 5. The app, with the task definition's flags.
{
  echo "PGHOST=$db"
  echo "PGPORT=5432"
  echo "PGSSLMODE=disable" # plain local Postgres; on AWS the image's verify-full applies
  echo "PUBLIC_BASE_URL=http://127.0.0.1:$port"
} >>"$envfile"
echo "   overrides: PGHOST=$db PGPORT=5432 PGSSLMODE=disable PUBLIC_BASE_URL=http://127.0.0.1:$port"
flags=()
[ "$(jq -r '.readonlyRootFilesystem' <<<"$container")" = true ] && flags+=(--read-only)
[ "$(jq -r '.linuxParameters.initProcessEnabled' <<<"$container")" = true ] && flags+=(--init)
docker run -d --name "$app" --network "$net" --label "$label" "${flags[@]}" \
  --env-file "$envfile" -p "127.0.0.1:$port:$(jq -r '.portMappings[0].containerPort' <<<"$container")" \
  --stop-timeout "$(jq -r '.stopTimeout // 30' <<<"$container")" "$image" >/dev/null

for _ in $(seq 1 30); do
  curl -fs "http://127.0.0.1:$port/readyz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fs "http://127.0.0.1:$port/readyz" >/dev/null ||
  { echo "!! App not ready:" >&2; docker logs --tail 20 "$app" >&2; exit 1; }
echo ">> $app running ${flags[*]} at http://127.0.0.1:$port (ready)"

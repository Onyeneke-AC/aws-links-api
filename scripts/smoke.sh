#!/usr/bin/env bash
# End-to-end check of a deployed environment through its public URL.
# Usage: scripts/smoke.sh http://links-dev-alb-123.eu-west-1.elb.amazonaws.com
# Used by `make smoke` and (later) by CI after each deploy.
set -euo pipefail

base="${1:?usage: smoke.sh <public_url>}"
target="https://example.com/smoke-$(date +%s)"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo ">> $base"

# Readiness may take a moment right after a deploy: retry for up to ~60 s.
for i in $(seq 1 12); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/readyz" || true)
  [ "$code" = 200 ] && break
  [ "$i" = 12 ] && fail "/readyz returned $code"
  sleep 5
done
echo "ok  /readyz 200"

body=$(curl -sf -X POST "$base/links" -H 'content-type: application/json' \
  -d "{\"url\":\"$target\"}") || fail "POST /links"
short=$(printf '%s' "$body" | sed -n 's/.*"code":"\([A-Za-z0-9]*\)".*/\1/p')
[ -n "$short" ] || fail "no code in response: $body"
echo "ok  POST /links -> $short"

loc=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$base/$short")
[ "$loc" = "302 $target" ] || fail "GET /$short returned '$loc'"
echo "ok  GET /$short -> 302 $target"

code=$(curl -s -o /dev/null -w '%{http_code}' "$base/zzzzzzz")
[ "$code" = 404 ] || fail "unknown code returned $code"
echo "ok  GET /zzzzzzz -> 404"

# The ALB blocks /metrics; locally the app serves it on purpose.
if [[ "$base" != *localhost* && "$base" != *127.0.0.1* ]]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/metrics")
  [ "$code" = 404 ] || fail "/metrics is public ($code)"
  echo "ok  /metrics hidden (404)"
fi

echo "SMOKE PASSED"

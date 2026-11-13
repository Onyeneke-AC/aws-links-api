#!/usr/bin/env bash
# End-to-end check of a deployed environment through its public URL.
# Usage: scripts/smoke.sh https://dxxxx.cloudfront.net [alb-dns-name]
# Used by `make smoke` and (later) by CI after each deploy.
set -euo pipefail

base="${1:?usage: smoke.sh <public_url> [alb_dns_name]}"
alb="${2:-}"
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

# Edge-only checks (locally the app serves /metrics and plain HTTP on purpose).
if [[ "$base" == https://* ]]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/metrics")
  [ "$code" = 404 ] || fail "/metrics is public ($code)"
  echo "ok  /metrics hidden (404)"

  code=$(curl -s -o /dev/null -w '%{http_code}' "http://${base#https://}/healthz")
  [ "$code" = 301 ] || fail "plain HTTP not redirected ($code)"
  echo "ok  http -> https redirect"
fi

if [ -n "$alb" ]; then
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$alb/healthz" || true)
  # 403 = listener refused (no secret header); 000 = SG dropped us (not CloudFront)
  case "$code" in 403|000) echo "ok  direct ALB refused ($code)";; *) fail "direct ALB answered $code";; esac
fi

echo "SMOKE PASSED"

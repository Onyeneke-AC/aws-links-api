#!/usr/bin/env bash
# Synthetic traffic: a steady mix of creates and redirects against an
# environment, with a one-line summary per minute.
#
#   1 in 4 requests: POST /links (new short link)
#   3 in 4 requests: GET /<code> of a link created earlier (302)
#
# On AWS the load balancer measures this traffic and publishes the metrics the
# SLO alarms read. The local AWS Emulator's load balancer publishes none, so
# when given a namespace this script publishes them itself, once a minute,
# under the ALB's metric names and LoadBalancer dimension, classifying each
# response the way the ALB would:
#   RequestCount              responses that came from the app (any status)
#   HTTPCode_Target_5XX_Count of those, 500-599 from the app
#   HTTPCode_ELB_5XX_Count    no response at all (refused/timeout): the ALB
#                             would have answered 502/503/504 itself
#   TargetResponseTime        seconds per app response
# Like the ALB, a 5xx count is only published when it isn't zero.
#
# usage: scripts/traffic.sh <base url> <minutes> [<namespace> <load balancer dimension>]
set -euo pipefail

base=${1:?base url} minutes=${2:?minutes} namespace=${3:-} lb=${4:-}
rps=${RPS:-5}
interval=$(awk "BEGIN { print 1 / $rps }")

publish() { # requests target5xx elb5xx times-file
  local data
  data=$(jq -n --arg lb "$lb" --argjson req "$1" --argjson t5 "$2" --argjson e5 "$3" \
    --slurpfile times <(jq -s . "$4") --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    [{ Name: "LoadBalancer", Value: $lb }] as $dims |
    ($times[0] | map(. * 1000 | round / 1000) | group_by(.) | .[:150]) as $buckets |
    [ { MetricName: "RequestCount", Value: $req, Unit: "Count", Dimensions: $dims, Timestamp: $ts } ]
    + (if $t5 > 0 then [{ MetricName: "HTTPCode_Target_5XX_Count", Value: $t5, Unit: "Count", Dimensions: $dims, Timestamp: $ts }] else [] end)
    + (if $e5 > 0 then [{ MetricName: "HTTPCode_ELB_5XX_Count", Value: $e5, Unit: "Count", Dimensions: $dims, Timestamp: $ts }] else [] end)
    + (if ($buckets | length) > 0 then [{ MetricName: "TargetResponseTime", Unit: "Seconds", Dimensions: $dims, Timestamp: $ts,
         Values: ($buckets | map(.[0])), Counts: ($buckets | map(length)) }] else [] end)')
  aws cloudwatch put-metric-data --namespace "$namespace" --metric-data "$data"
}

times=$(mktemp)
trap 'rm -f "$times"' EXIT
codes=() n=0 requests=0 target5xx=0 elb5xx=0 other=0
end=$((SECONDS + minutes * 60)) window_end=$((SECONDS + 60))

echo ">> ${rps} req/s against $base for ${minutes} min${namespace:+, publishing ALB metrics to $namespace}"
while [ "$SECONDS" -lt "$end" ]; do
  if [ $((n % 4)) = 0 ] || [ ${#codes[@]} = 0 ]; then
    out=$(curl -s -m 5 -w '\n%{http_code} %{time_total}' -X POST "$base/links" \
      -H 'content-type: application/json' -d "{\"url\":\"https://example.com/load/$n\"}" || true)
    code=$(sed -n 's/.*"code":"\([A-Za-z0-9]*\)".*/\1/p' <<<"$out" | head -1)
    [ -n "$code" ] && codes+=("$code")
  else
    out=$(curl -s -m 5 -o /dev/null -w '\n%{http_code} %{time_total}' \
      "$base/${codes[RANDOM % ${#codes[@]}]}" || true)
  fi
  read -r status seconds <<<"$(tail -1 <<<"$out")"
  if [ "${status:-000}" = 000 ]; then
    elb5xx=$((elb5xx + 1))
  else
    requests=$((requests + 1))
    echo "$seconds" >>"$times"
    case $status in 5*) target5xx=$((target5xx + 1)) ;; 2* | 3*) ;; *) other=$((other + 1)) ;; esac
  fi
  n=$((n + 1))

  if [ "$SECONDS" -ge "$window_end" ] || [ "$SECONDS" -ge "$end" ]; then
    failed=$((target5xx + elb5xx)) total=$((requests + elb5xx))
    printf '%s  requests=%-4s app5xx=%-4s no-response=%-4s other=%-3s error-rate=%s%%\n' \
      "$(date -u +%H:%M:%S)" "$requests" "$target5xx" "$elb5xx" "$other" \
      "$(awk "BEGIN { printf \"%.1f\", $total ? 100 * $failed / $total : 0 }")"
    [ -n "$namespace" ] && publish "$requests" "$target5xx" "$elb5xx" "$times"
    : >"$times"
    requests=0 target5xx=0 elb5xx=0 other=0 window_end=$((SECONDS + 60))
  fi
  sleep "$interval"
done

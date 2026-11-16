#!/usr/bin/env bash
# AWS Emulator only: prove the SLO alarm works end to end, as a pass/fail test.
#
#   1. synthetic traffic starts (scripts/traffic.sh publishes the ALB metrics)
#   2. after a healthy minute: the SLO alarm must be OK
#   3. the database is stopped: every request now fails
#   4. the SLO alarm must go to ALARM and its notification must reach the inbox
#   5. the database is started: the app must serve requests again
#   6. (WAIT_FOR_OK=1 only) the alarm must clear and send its "resolved"
#      notification; takes ~5 more minutes, the 5-minute window must be clean
# Each step has a deadline; missing one fails the test. Used by
# `make emu-chaos-test` and the PR pipeline's emulator job.
#
# usage: scripts/emulator-chaos-test.sh <app url> <alarm> <inbox queue> <db container> <namespace> <lb dimension>
set -euo pipefail

url=${1:?app url} alarm=${2:?alarm} inbox=${3:?inbox queue} db=${4:?db container} ns=${5:?namespace} lb=${6:?lb}
wait_for_ok=${WAIT_FOR_OK:-0}
here=$(dirname "$0")

[ "$(aws sts get-caller-identity --query Account --output text)" = 000000000000 ] ||
  { echo "!! Not the AWS Emulator (account 000000000000): refusing" >&2; exit 1; }

start=$SECONDS
log() { printf '%s  +%3ss  %s\n' "$(date -u +%H:%M:%S)" $((SECONDS - start)) "$*" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
state() { aws cloudwatch describe-alarms --alarm-types CompositeAlarm --alarm-names "$alarm" \
  --query 'CompositeAlarms[0].StateValue' --output text; }
# A function, so each retry reads the alarm again: the state passed in as an
# argument would be read once, before the first try.
alarm_is() { [ "$(state)" = "$1" ]; }
inbox_has() { "$here/emulator-alarm-inbox.sh" read "$inbox" | grep -q "$alarm: $1"; }
wait_until() { # <seconds> <description> <command...>
  local deadline=$((SECONDS + $1)) what=$2; shift 2
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || { log "FAIL: $what (not within the deadline)"; exit 1; }
    sleep 5
  done
  log "ok    $what"
}

minutes=$([ "$wait_for_ok" = 1 ] && echo 12 || echo 5)
traffic_log=$(mktemp)
"$here/traffic.sh" "$url" "$minutes" "$ns" "$lb" >"$traffic_log" 2>&1 &
traffic=$!
cleanup() {
  kill "$traffic" 2>/dev/null || true
  docker start "$db" >/dev/null 2>&1 || true
  echo "--- traffic, per minute:"; grep -E '^[0-9]{2}:' "$traffic_log" || true
  rm -f "$traffic_log"
}
trap cleanup EXIT

[ "${GITHUB_STEP_SUMMARY:-}" ] && printf '### SLO alarm chaos test (AWS Emulator)\n```\n' >>"$GITHUB_STEP_SUMMARY"
log "traffic started against $url"
sleep 70
wait_until 30 "healthy: $alarm is OK" alarm_is OK

docker stop "$db" >/dev/null
log "chaos: database $db stopped"
wait_until 240 "$alarm went to ALARM" alarm_is ALARM
wait_until 60 "ALARM notification in the inbox" inbox_has "OK -> ALARM"

docker start "$db" >/dev/null
log "recovery: database $db started"
wait_until 60 "app serves requests again" \
  curl -fs -X POST "$url/links" -H 'content-type: application/json' -d '{"url":"https://example.com/recovered"}' -o /dev/null

if [ "$wait_for_ok" = 1 ]; then
  wait_until 480 "$alarm cleared (OK)" alarm_is OK
  wait_until 60 "OK notification in the inbox" inbox_has "ALARM -> OK"
fi
log "PASSED"
[ "${GITHUB_STEP_SUMMARY:-}" ] && printf '```\n' >>"$GITHUB_STEP_SUMMARY"
exit 0

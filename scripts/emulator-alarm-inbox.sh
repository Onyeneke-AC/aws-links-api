#!/usr/bin/env bash
# AWS Emulator only: an inbox for the SLO alarm's notifications.
#
# On AWS the alerts SNS topic emails people (TF_VAR_alarm_email). The emulator
# sends no email, so an SQS queue subscribed to the same topic shows exactly
# what would have been sent, when, and why.
#
#   setup <topic arn> <queue name>   create the queue and subscribe it
#   read  <queue name>               print the notifications received so far
set -euo pipefail

[ "$(aws sts get-caller-identity --query Account --output text)" = 000000000000 ] ||
  { echo "!! Not the AWS Emulator (account 000000000000): refusing" >&2; exit 1; }

case ${1:-} in
setup)
  topic=${2:?topic arn} queue=${3:?queue name}
  url=$(aws sqs create-queue --queue-name "$queue" --query QueueUrl --output text)
  arn=$(aws sqs get-queue-attributes --queue-url "$url" --attribute-names QueueArn --query Attributes.QueueArn --output text)
  # As on AWS, a queue only accepts messages from SNS if its policy says so.
  policy=$(jq -cn --arg q "$arn" --arg t "$topic" '{Version: "2012-10-17", Statement: [{
    Effect: "Allow", Principal: { Service: "sns.amazonaws.com" }, Action: "sqs:SendMessage",
    Resource: $q, Condition: { ArnEquals: { "aws:SourceArn": $t } } }]}')
  aws sqs set-queue-attributes --queue-url "$url" --attributes "$(jq -cn --arg p "$policy" '{Policy: $p}')"
  aws sns subscribe --topic-arn "$topic" --protocol sqs --notification-endpoint "$arn" >/dev/null
  echo ">> Alarm inbox $queue subscribed to ${topic##*:}"
  ;;
read)
  queue=${2:?queue name}
  url=$(aws sqs get-queue-url --queue-name "$queue" --query QueueUrl --output text)
  # Visibility 0: reading doesn't consume, so the inbox can be read again.
  aws sqs receive-message --queue-url "$url" --max-number-of-messages 10 --visibility-timeout 0 \
    --wait-time-seconds 1 --query 'Messages[].Body' --output json |
    jq -r '(. // [])[] | fromjson | .Message | fromjson |
      "\(.StateChangeTime)  \(.AlarmName): \(.OldStateValue) -> \(.NewStateValue)\n    \(.NewStateReason)"' |
    sort
  ;;
*)
  echo "usage: $0 setup <topic arn> <queue name> | read <queue name>" >&2
  exit 2
  ;;
esac

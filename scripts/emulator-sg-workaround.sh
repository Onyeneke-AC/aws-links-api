#!/usr/bin/env bash
# AWS Emulator only: works around aws/aws-emulator#46.
# https://github.com/aws/aws-emulator/issues/46
#
# Right after creating a security group, Terraform removes AWS's default
# "allow all outbound" rule, naming it with FromPort/ToPort 0. AWS matches an
# all-protocols rule whatever the ports; the emulator compares them exactly,
# answers InvalidPermission.NotFound, and Terraform marks the group tainted
# (it would destroy and recreate it next time, failing the same way).
#
# For each tainted security group: remove the default rule the way the
# emulator matches it (no ports), then untaint it. The next apply carries on
# exactly where real AWS would have been.
#
# usage: scripts/emulator-sg-workaround.sh <terraform dir>
set -euo pipefail

dir=${1:?terraform dir}
[ "$(aws sts get-caller-identity --query Account --output text)" = 000000000000 ] ||
  { echo "!! Not the AWS Emulator (account 000000000000): refusing" >&2; exit 1; }

state=$(terraform -chdir="$dir" show -json)
tainted=$(jq -r '.values.root_module | .. | objects | select(.type? == "aws_security_group" and .tainted? == true) | "\(.address) \(.values.id)"' <<<"$state")
[ -n "$tainted" ] || { echo "!! No tainted security groups: the failure was something else" >&2; exit 1; }

while read -r address id; do
  aws ec2 revoke-security-group-egress --group-id "$id" \
    --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null
  terraform -chdir="$dir" untaint "$address"
done <<<"$tainted"

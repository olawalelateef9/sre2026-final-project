#!/usr/bin/env bash
# Report billable resources left in the project region. Exit code 1 if any are found.
# Run after scripts/down.sh, or any time you want to confirm spend has stopped.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require aws

REGION=${REGION:-$(bootstrap_output region)}
REGION=${REGION:-eu-west-2}

count() { aws "$@" --region "$REGION" --output text 2>/dev/null || echo "?"; }

declare -A found=(
  ["EKS clusters"]=$(count eks list-clusters --query 'length(clusters)')
  ["NAT gateways"]=$(count ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'length(NatGateways)')
  ["Load balancers"]=$(count elbv2 describe-load-balancers --query 'length(LoadBalancers)')
  ["Classic load balancers"]=$(count elb describe-load-balancers --query 'length(LoadBalancerDescriptions)')
  ["Running/pending EC2 instances"]=$(count ec2 describe-instances --filters Name=instance-state-name,Values=pending,running --query 'length(Reservations[].Instances[])')
  ["Unattached EBS volumes"]=$(count ec2 describe-volumes --filters Name=status,Values=available --query 'length(Volumes)')
  ["Elastic IPs"]=$(count ec2 describe-addresses --query 'length(Addresses)')
  ["RDS instances"]=$(count rds describe-db-instances --query 'length(DBInstances)')
  ["ElastiCache clusters"]=$(count elasticache describe-cache-clusters --query 'length(CacheClusters)')
  ["Non-default VPCs"]=$(count ec2 describe-vpcs --filters Name=is-default,Values=false --query 'length(Vpcs)')
)

printf '\nBillable resources in %s:\n' "$REGION"
leftovers=0
for kind in "${!found[@]}"; do
  value=${found[$kind]}
  printf '  %-32s %s\n' "$kind" "$value"
  [[ "$value" == "0" ]] || leftovers=1
done

if [[ $leftovers -eq 0 ]]; then
  printf '\nOK: nothing billable is left running (bootstrap bucket, budget and backup secret are kept).\n'
else
  printf '\nWARNING: resources remain. Investigate before leaving them running.\n'
  exit 1
fi

#!/usr/bin/env bash
# SkySpot preflight: fail loud BEFORE you launch a job.
#
# Checks:
#   1. SkyPilot can talk to AWS (sky check aws).
#   2. The target VPC exists in every candidate region, with private subnets.
#
# Why: a missing VPC in even one candidate region makes SkyPilot abort the whole
# multi-region spot failover chain. Catch it here, not 20 minutes into a launch.
#
# Usage:
#   ./preflight.sh                              # defaults: skyspot-vpc in the trio
#   ./preflight.sh skyspot-vpc "eu-north-1 ap-south-1 us-east-1"
set -uo pipefail

VPC_NAME="${1:-skyspot-vpc}"
REGIONS="${2:-eu-north-1 ap-south-1 us-east-1}"

fail=0

echo "== 1. sky check aws =="
if ! sky check aws; then
  echo "  SkyPilot cannot use AWS. Run 'sky check' and fix credentials first."
  fail=1
fi

echo
echo "== 2. VPC '${VPC_NAME}' per region =="
for r in ${REGIONS}; do
  vpc_id=$(aws ec2 describe-vpcs --region "$r" \
    --filters "Name=tag:Name,Values=${VPC_NAME}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

  if [ -z "$vpc_id" ] || [ "$vpc_id" == "None" ]; then
    echo "  [MISSING] ${r}: no VPC named '${VPC_NAME}'."
    echo "            fix: (cd infra/vpc && terraform apply -var=\"region=${r}\")"
    echo "            or remove ${r} from the recipe's any_of: block."
    fail=1
    continue
  fi

  subnets=$(aws ec2 describe-subnets --region "$r" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Tier,Values=private-workload" \
    --query 'length(Subnets)' --output text 2>/dev/null)

  if [ -z "$subnets" ] || [ "$subnets" == "0" ] || [ "$subnets" == "None" ]; then
    echo "  [WARN]    ${r}: ${vpc_id} found but no private-workload subnets."
    fail=1
  else
    echo "  [OK]      ${r}: ${vpc_id} (${subnets} private subnets)"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "Preflight PASSED - safe to launch."
else
  echo "Preflight FAILED - fix the items above before launching."
fi
exit $fail

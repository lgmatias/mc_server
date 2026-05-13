#!/usr/bin/env bash
# Deploy the single shared S3 bucket used by backup-world.sh.
# Run this once for your AWS account, in whichever region you want the bucket
# to live in. The bucket name is mc-worlds-<account-id> (no region suffix), so
# servers in any region can write to the same bucket.
#
# Usage: ./deploy-worlds-bucket.sh [region]

set -euo pipefail

REGION="${1:-us-east-1}"
STACK_NAME="mc-worlds-bucket"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../cloudformation/worlds-bucket.yml"

echo "Deploying worlds-bucket stack '$STACK_NAME' in $REGION..."

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --no-fail-on-empty-changeset

echo ""
aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table

echo ""
echo "Bucket has DeletionPolicy=Retain — deleting this stack will not delete backups."
echo "Note: data uploads from EC2 in other regions cross AWS regions (~\$0.02/GB transfer cost)."

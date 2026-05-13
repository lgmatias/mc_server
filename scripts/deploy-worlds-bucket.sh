#!/usr/bin/env bash
# Deploy the shared S3 bucket used by backup-world.sh.
# Run this once per AWS region before deploying any server stacks. Idempotent.
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

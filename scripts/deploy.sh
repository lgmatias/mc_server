#!/usr/bin/env bash
# Deploy a vanilla Minecraft server via CloudFormation.
# Usage: ./deploy.sh <stack-name> <key-pair-name> [minecraft-version] [instance-type] [region]
#
# Examples:
#   ./deploy.sh mc-1204 my-key-pair 1.20.4
#   ./deploy.sh mc-1165 my-key-pair 1.16.5 t3.large us-west-2

set -euo pipefail

STACK_NAME="${1:?Usage: $0 <stack-name> <key-pair-name> [mc-version] [instance-type] [region]}"
KEY_PAIR="${2:?Usage: $0 <stack-name> <key-pair-name> [mc-version] [instance-type] [region]}"
MC_VERSION="${3:-1.20.4}"
INSTANCE_TYPE="${4:-t3.medium}"
REGION="${5:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../cloudformation/mc-server.yml"

echo "Deploying Minecraft $MC_VERSION server as stack '$STACK_NAME' in $REGION..."

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --parameter-overrides \
    MinecraftVersion="$MC_VERSION" \
    InstanceType="$INSTANCE_TYPE" \
    KeyPairName="$KEY_PAIR" \
  --no-fail-on-empty-changeset

echo ""
echo "Stack deployed. Server details:"
aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table

echo ""
echo "The server process starts automatically. Allow ~2 minutes for first-run setup."
echo "Monitor setup progress via SSH: sudo tail -f /var/log/mc-setup.log"

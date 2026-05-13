#!/usr/bin/env bash
# Deploy a Minecraft 1.8.9 PGM server via CloudFormation.
# Usage: ./deploy-pgm.sh <stack-name> <key-pair-name> [instance-type] [region]
#
# Examples:
#   ./deploy-pgm.sh pgm-server my-key-pair
#   ./deploy-pgm.sh pgm-server my-key-pair t3.large us-west-2

set -euo pipefail

STACK_NAME="${1:?Usage: $0 <stack-name> <key-pair-name> [instance-type] [region]}"
KEY_PAIR="${2:?Usage: $0 <stack-name> <key-pair-name> [instance-type] [region]}"
INSTANCE_TYPE="${3:-t3.medium}"
REGION="${4:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../cloudformation/pgm-server.yml"

echo "Deploying PGM 1.8.9 server as stack '$STACK_NAME' in $REGION..."

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --parameter-overrides \
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
echo "Next steps:"
echo "  1. SSH into the server (see SSHAccess output above)"
echo "  2. Upload PGM map folders to /opt/minecraft/maps/"
echo "     Each map needs a map.xml — see https://pgm.dev/docs/map/"
echo "  3. Restart the server: sudo systemctl restart minecraft"
echo ""
echo "Monitor setup: sudo tail -f /var/log/mc-pgm-setup.log"

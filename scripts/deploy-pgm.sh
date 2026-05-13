#!/usr/bin/env bash
# Deploy or update the PGM 1.8.9 server. The stack name is fixed at 'pgm'.
# Re-deploying with a different instance size replaces the instance but reuses
# the existing EBS data volume (worlds, maps, and configs are preserved).
#
# Usage: ./deploy-pgm.sh [instance-type] [volume-size-gb] [region]
#
# Examples:
#   ./deploy-pgm.sh
#   ./deploy-pgm.sh t3.large
#   ./deploy-pgm.sh t3.medium 30 us-west-2

set -euo pipefail

INSTANCE_TYPE="${1:-t3.medium}"
VOLUME_SIZE="${2:-20}"
REGION="${3:-us-east-1}"

STACK_NAME="pgm"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../cloudformation/pgm-server.yml"

echo "Deploying PGM 1.8.9 server as stack '$STACK_NAME' in $REGION..."
echo "  Instance type: $INSTANCE_TYPE"
echo "  Volume size:   ${VOLUME_SIZE} GB"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    InstanceType="$INSTANCE_TYPE" \
    VolumeSize="$VOLUME_SIZE" \
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
echo "  1. Open a shell on the instance via Session Manager (see SessionManagerConsole URL above)"
echo "  2. Upload PGM map folders to /opt/minecraft/maps/ — each map needs a map.xml"
echo "     See https://pgm.dev/docs/map/ for the map spec"
echo "  3. Restart the server after adding maps: sudo systemctl restart minecraft"

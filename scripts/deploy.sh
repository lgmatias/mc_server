#!/usr/bin/env bash
# Deploy or update a vanilla Minecraft server. One stack per Minecraft version.
# The stack name is derived from the version (e.g. 1.20.4 -> mc-1-20-4) so re-deploying
# the same version with a different instance size replaces the instance but reuses the
# existing EBS data volume (the world is preserved).
#
# Usage: ./deploy.sh <minecraft-version> [instance-type] [volume-size-gb] [region]
#
# Examples:
#   ./deploy.sh 1.20.4
#   ./deploy.sh 1.20.4 t3.large
#   ./deploy.sh 1.16.5 t3.medium 30 us-west-2

set -euo pipefail

MC_VERSION="${1:?Usage: $0 <minecraft-version> [instance-type] [volume-size] [region]}"
INSTANCE_TYPE="${2:-t3.medium}"
VOLUME_SIZE="${3:-20}"
REGION="${4:-us-east-1}"

STACK_NAME="mc-$(echo "$MC_VERSION" | tr '.' '-')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../cloudformation/mc-server.yml"

echo "Deploying Minecraft $MC_VERSION as stack '$STACK_NAME' in $REGION..."
echo "  Instance type: $INSTANCE_TYPE"
echo "  Volume size:   ${VOLUME_SIZE} GB"

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    MinecraftVersion="$MC_VERSION" \
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
echo "First deploy: allow ~2 minutes for the server jar to download and start."
echo "Re-deploys reuse the existing EBS volume and skip the download."
echo ""
echo "Open a shell on the instance via Session Manager (no SSH key needed):"
echo "  - Browser: open the SessionManagerConsole URL above"
echo "  - CloudShell or local CLI: run the SessionManagerCLI command above"

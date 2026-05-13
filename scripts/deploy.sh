#!/usr/bin/env bash
# Deploy or update a vanilla Minecraft server. One stack per Minecraft version
# globally — if mc-X-Y-Z already exists in a different region, this script will
# snapshot its EBS volume, copy the snapshot to the target region, deploy the new
# stack there using the snapshot as the volume's seed, and then delete the old
# stack and orphaned volume.
#
# The stack name is derived from the version (1.20.4 -> mc-1-20-4).
#
# Usage: ./deploy.sh <minecraft-version> [instance-type] [volume-size-gb] [region]
#
# Examples:
#   ./deploy.sh 1.20.4
#   ./deploy.sh 1.20.4 t3.large
#   ./deploy.sh 1.16.5 t3.medium 30 us-west-2     # if this version already exists
#                                                  # in another region, it is migrated

set -euo pipefail

MC_VERSION="${1:?Usage: $0 <minecraft-version> [instance-type] [volume-size] [region]}"
INSTANCE_TYPE="${2:-t3.medium}"
VOLUME_SIZE="${3:-20}"
REGION="${4:-us-east-1}"

STACK_NAME="mc-$(echo "$MC_VERSION" | tr '.' '-')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../cloudformation/mc-server.yml"

# shellcheck source=lib/migrate.sh
source "$SCRIPT_DIR/lib/migrate.sh"

echo "Target: Minecraft $MC_VERSION as stack '$STACK_NAME' in $REGION"
echo "  Instance type: $INSTANCE_TYPE"
echo "  Volume size:   ${VOLUME_SIZE} GB"
echo ""

prepare_migration_if_needed "$REGION" "$STACK_NAME"

# Build parameter overrides
PARAMS=("MinecraftVersion=$MC_VERSION" "InstanceType=$INSTANCE_TYPE")

if [ -n "$MIGRATION_DEST_SNAPSHOT" ]; then
  # When restoring from snapshot, volume size must be >= source. If user asked
  # for less, bump it up so the deploy doesn't fail.
  if [ -n "$MIGRATION_VOLUME_SIZE" ] && [ "$MIGRATION_VOLUME_SIZE" -gt "$VOLUME_SIZE" ]; then
    echo "Note: increasing VolumeSize from $VOLUME_SIZE to $MIGRATION_VOLUME_SIZE GB (source volume size)."
    VOLUME_SIZE="$MIGRATION_VOLUME_SIZE"
  fi
  PARAMS+=("VolumeSize=$VOLUME_SIZE" "SnapshotId=$MIGRATION_DEST_SNAPSHOT")
else
  PARAMS+=("VolumeSize=$VOLUME_SIZE")
fi

echo "Deploying stack..."
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides "${PARAMS[@]}" \
  --no-fail-on-empty-changeset

finalize_migration_if_needed "$REGION"

echo ""
echo "Stack deployed. Server details:"
aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table

echo ""
echo "First deploy: allow ~2 minutes for the server jar to download and start."
echo "Connect to the instance via Session Manager — see the SessionManagerConsole URL above."

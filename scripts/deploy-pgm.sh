#!/usr/bin/env bash
# Deploy or update the PGM 1.8.9 server. The stack name is fixed at 'pgm' and
# may only exist in one region — if it already exists in a different region,
# this script migrates it (snapshot + cross-region copy + redeploy + delete old).
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

# shellcheck source=lib/migrate.sh
source "$SCRIPT_DIR/lib/migrate.sh"

echo "Target: PGM 1.8.9 as stack '$STACK_NAME' in $REGION"
echo "  Instance type: $INSTANCE_TYPE"
echo "  Volume size:   ${VOLUME_SIZE} GB"
echo ""

prepare_migration_if_needed "$REGION" "$STACK_NAME"

PARAMS=("InstanceType=$INSTANCE_TYPE")

if [ -n "$MIGRATION_DEST_SNAPSHOT" ]; then
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
echo "Next steps:"
echo "  1. Open Session Manager from the SessionManagerConsole URL above"
echo "  2. Upload PGM map folders to /opt/minecraft/maps/ — each map needs a map.xml"
echo "     See https://pgm.dev/docs/map/ for the map spec"
echo "  3. Restart the server after adding maps: sudo systemctl restart minecraft"

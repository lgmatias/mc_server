#!/usr/bin/env bash
# Tear down a single stack and (by default) delete its retained EBS data
# volume. Use this when you want to fully wipe a stack so the next deploy gets
# a fresh empty volume — for example to shrink VolumeSize (EBS can't shrink
# in place) or to iterate quickly during testing.
#
# What this script does:
#   1. Delete the CloudFormation stack (terminates the EC2 instance, security
#      group, IAM role, etc.).
#   2. Delete the retained EBS data volume (per DeletionPolicy: Retain, the
#      volume survives stack deletion otherwise).
#
# What this script does NOT touch:
#   - The shared mc-worlds-<account> S3 bucket (your saved worlds survive).
#   - Any other stack in this or other regions.
#   - The mc-worlds-bucket CFN stack.
#
# Usage: ./terminate.sh <minecraft-version|pgm> [region] [--keep-volume] [--yes]
#
# Examples:
#   ./terminate.sh 1.8.9                       # vanilla in us-east-1, delete volume, prompt
#   ./terminate.sh 1.8.9 us-west-1 --yes       # no prompt
#   ./terminate.sh pgm --keep-volume           # tear down PGM, keep the EBS volume
#
# Flags:
#   --keep-volume   Skip EBS volume deletion (keep on-volume data)
#   --yes, -y       Skip the confirmation prompt
#   --help, -h      Show this usage and exit

set -euo pipefail

KEEP_VOLUME=false
ASSUME_YES=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-volume) KEEP_VOLUME=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# Flags:/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

TARGET="${POSITIONAL[0]:?Usage: $0 <minecraft-version|pgm> [region] [--keep-volume] [--yes]}"
REGION="${POSITIONAL[1]:-us-east-1}"

if [ "$TARGET" = "pgm" ]; then
  STACK_NAME="pgm"
else
  STACK_NAME="mc-$(echo "$TARGET" | tr '.' '-')"
fi

# Bail early if the stack doesn't exist — no work to do.
if ! aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  echo "Stack '$STACK_NAME' not found in $REGION — nothing to do."
  exit 0
fi

# Resolve identifiers from stack outputs BEFORE deleting (after deletion the
# outputs are gone). DataVolumeId is needed for the post-delete cleanup;
# InstanceId/state is just for the warning if minecraft is still running.
# StackStatus lets us detect stuck rollback states and recover before delete.
STACK_STATUS=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "")
DATA_VOLUME_ID=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DataVolumeId'].OutputValue | [0]" \
  --output text 2>/dev/null || echo "")
# If outputs are unavailable (e.g. stack rolled back before reaching CREATE_COMPLETE),
# fall back to describe-stack-resources to find the DataVolume.
if [ -z "$DATA_VOLUME_ID" ] || [ "$DATA_VOLUME_ID" = "None" ]; then
  DATA_VOLUME_ID=$(aws cloudformation describe-stack-resources --region "$REGION" --stack-name "$STACK_NAME" \
    --logical-resource-id DataVolume --query "StackResources[0].PhysicalResourceId" \
    --output text 2>/dev/null || echo "")
fi
INSTANCE_ID=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]" \
  --output text 2>/dev/null || echo "")
INSTANCE_STATE=""
if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
  INSTANCE_STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "")
fi

echo "About to terminate stack '$STACK_NAME' in $REGION:"
echo "  - Delete CloudFormation stack (instance $INSTANCE_ID, state: $INSTANCE_STATE)"
if [ "$KEEP_VOLUME" = "true" ]; then
  echo "  - KEEP EBS data volume ${DATA_VOLUME_ID:-(none)} (per DeletionPolicy: Retain)"
else
  if [ -n "$DATA_VOLUME_ID" ] && [ "$DATA_VOLUME_ID" != "None" ]; then
    echo "  - Delete EBS data volume $DATA_VOLUME_ID (all on-volume data lost)"
  else
    echo "  - No data volume in stack outputs (skip volume cleanup)"
  fi
fi
echo "  - Shared S3 bucket s3://mc-worlds-<account>/ is NOT touched."

# For vanilla stacks, the world lives on the data volume until server-stop.sh
# pushes it to S3. If the instance is running and the user hasn't pushed, the
# in-memory + on-volume state is about to be lost. PGM is map-based — no world
# to save — so no warning there.
if [ "$INSTANCE_STATE" = "running" ] && [ "$TARGET" != "pgm" ]; then
  echo
  echo "WARNING: instance is running. If you have unsaved world changes, run"
  echo "    ./server-stop.sh $TARGET $REGION"
  echo "  first to push the current world to S3 before terminating."
fi
echo

if [ "$ASSUME_YES" != "true" ]; then
  read -p "Type '$STACK_NAME' to confirm: " ans
  if [ "$ans" != "$STACK_NAME" ]; then
    echo "Aborted."
    exit 1
  fi
fi

# If the stack is wedged in *_ROLLBACK_FAILED, delete-stack will fail. Unstick
# it first by skipping the DataVolume (the resource we'd delete anyway) so the
# rollback can complete. This is the same manual recovery we did for the
# us-west-1 stack earlier in development.
case "$STACK_STATUS" in
  UPDATE_ROLLBACK_FAILED|ROLLBACK_FAILED)
    echo "Stack is in $STACK_STATUS — running continue-update-rollback (skipping DataVolume)..."
    aws cloudformation continue-update-rollback --region "$REGION" --stack-name "$STACK_NAME" \
      --resources-to-skip DataVolume 2>&1 || true
    aws cloudformation wait stack-rollback-complete --region "$REGION" --stack-name "$STACK_NAME" 2>&1 || true
    ;;
esac

echo "Deleting stack '$STACK_NAME'..."
aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK_NAME"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK_NAME"
echo "Stack deleted."

if [ "$KEEP_VOLUME" != "true" ] && [ -n "$DATA_VOLUME_ID" ] && [ "$DATA_VOLUME_ID" != "None" ]; then
  STATE=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$DATA_VOLUME_ID" \
    --query "Volumes[0].State" --output text 2>/dev/null || echo "")
  if [ "$STATE" = "available" ]; then
    echo "Deleting retained EBS volume $DATA_VOLUME_ID..."
    aws ec2 delete-volume --region "$REGION" --volume-id "$DATA_VOLUME_ID"
    echo "Volume deleted."
  elif [ -z "$STATE" ]; then
    echo "Note: volume $DATA_VOLUME_ID not found (already deleted?)."
  else
    echo "Warning: volume $DATA_VOLUME_ID is in state '$STATE' (expected 'available')." >&2
    echo "Skipping auto-delete. Manual cleanup:" >&2
    echo "  aws ec2 delete-volume --region $REGION --volume-id $DATA_VOLUME_ID" >&2
  fi
fi

echo
echo "terminate complete."

#!/usr/bin/env bash
# Stop the EC2 instance for a Minecraft server.
#
# For vanilla stacks (mc-X-Y-Z): before stopping, sync the world directories
# from the data volume up to s3://mc-worlds-<account>/<version>/<dim>/ (one
# top-level prefix per dimension: world, world_nether, world_the_end). This is
# the canonical world for that version; --delete on the sync keeps S3 in
# lockstep with the on-disk state. server-start.sh pulls this back down on the
# next start. No tarball — incremental sync transfers only changed region files.
#
# For PGM: no world auto-save (PGM maps live in s3://.../pgm-maps/ and are
# managed manually). The instance is just stopped.
#
# Compute billing is paused while stopped; the EBS data volume still bills.
#
# Usage: ./server-stop.sh <minecraft-version|pgm> [region]
#
# Examples:
#   ./server-stop.sh 1.20.4
#   ./server-stop.sh pgm

set -euo pipefail

TARGET="${1:?Usage: $0 <minecraft-version|pgm> [region]}"
REGION="${2:-us-east-1}"

if [ "$TARGET" = "pgm" ]; then
  STACK_NAME="pgm"
  IS_PGM=true
else
  STACK_NAME="mc-$(echo "$TARGET" | tr '.' '-')"
  IS_PGM=false
fi

INSTANCE_ID=$(aws cloudformation describe-stacks \
  --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text 2>/dev/null || true)
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "Error: stack '$STACK_NAME' not found in $REGION." >&2
  exit 1
fi

STATE=$(aws ec2 describe-instances \
  --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)

# Save world to S3 first (vanilla, running only).
if [ "$STATE" = "running" ] && [ "$IS_PGM" = "false" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  BUCKET="mc-worlds-${ACCOUNT_ID}"
  BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" \
    --query 'LocationConstraint' --output text 2>/dev/null || echo "")
  if [ -z "$BUCKET_REGION" ] || [ "$BUCKET_REGION" = "None" ] || [ "$BUCKET_REGION" = "null" ]; then
    if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
      BUCKET_REGION=us-east-1
    else
      echo "Warning: worlds bucket '$BUCKET' not found. Skipping save." >&2
      BUCKET=""
    fi
  fi

  if [ -n "$BUCKET" ]; then
    echo "Saving world to s3://$BUCKET/$TARGET/..."

    REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
cd /opt/minecraft
TARGETS=""
for d in world world_nether world_the_end; do
  [ -d "$d" ] && TARGETS="$TARGETS $d"
done
if [ -z "$TARGETS" ]; then
  echo "No world directories on this instance — nothing to save."
  exit 0
fi
echo "Stopping minecraft and syncing:$TARGETS"
systemctl stop minecraft || true
for d in $TARGETS; do
  echo "Syncing $d -> s3://__BUCKET__/__VERSION__/$d/"
  aws --region __BUCKET_REGION__ s3 sync "$d" "s3://__BUCKET__/__VERSION__/$d/" --delete
done
echo "Save complete."
REMOTE
)
    REMOTE_SCRIPT="${REMOTE_SCRIPT//__BUCKET__/$BUCKET}"
    REMOTE_SCRIPT="${REMOTE_SCRIPT//__VERSION__/$TARGET}"
    REMOTE_SCRIPT="${REMOTE_SCRIPT//__BUCKET_REGION__/$BUCKET_REGION}"

    SCRIPT_B64=$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\n')

    COMMAND_ID=$(aws ssm send-command \
      --region "$REGION" \
      --instance-ids "$INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --parameters "{\"commands\":[\"echo $SCRIPT_B64 | base64 -d | bash\"]}" \
      --query 'Command.CommandId' --output text)

    echo -n "Waiting for save"
    while true; do
      SS=$(aws ssm get-command-invocation \
        --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
        --query 'Status' --output text 2>/dev/null || echo Pending)
      case "$SS" in
        Pending|InProgress|Delayed) echo -n "."; sleep 5 ;;
        Success) echo " done."; break ;;
        *)
          echo ""
          echo "Save failed (status: $SS) — continuing with instance stop." >&2
          aws ssm get-command-invocation \
            --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
            --query 'StandardErrorContent' --output text >&2 || true
          break
          ;;
      esac
    done
  fi
fi

echo "Stopping instance $INSTANCE_ID..."
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --output text --query 'StoppingInstances[0].CurrentState.Name' >/dev/null

aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "Instance stopped."

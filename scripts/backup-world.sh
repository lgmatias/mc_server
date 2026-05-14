#!/usr/bin/env bash
# Snapshot the Minecraft world from the EBS data volume of a server stack and
# upload it to the shared S3 bucket (mc-worlds-<account>). Works whether the
# instance is running or stopped — a stopped instance is started temporarily
# for the snapshot and stopped again afterwards.
#
# Snapshots land at (one prefix per timestamp, one sub-prefix per directory):
#   s3://mc-worlds-<account>/<version>/snapshots/YYYYMMDDTHHMMSSZ/<dir>/...
# where <dir> is one of: world, world_nether, world_the_end, maps.
#
# Prerequisites:
#   - deploy-worlds-bucket.sh has been run (creates the bucket)
#   - The target server stack has been deployed
#
# Usage: ./backup-world.sh <minecraft-version|pgm> [region]
#
# Examples:
#   ./backup-world.sh 1.20.4
#   ./backup-world.sh pgm us-west-2

set -euo pipefail

TARGET="${1:?Usage: $0 <minecraft-version|pgm> [region]}"
REGION="${2:-us-east-1}"

if [ "$TARGET" = "pgm" ]; then
  STACK_NAME="pgm"
  S3_PREFIX="pgm"
else
  STACK_NAME="mc-$(echo "$TARGET" | tr '.' '-')"
  S3_PREFIX="$TARGET"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="mc-worlds-${ACCOUNT_ID}"

# Discover where the bucket lives (us-east-1 returns null from get-bucket-location).
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" \
  --query 'LocationConstraint' --output text 2>/dev/null || echo "")
if [ -z "$BUCKET_REGION" ] || [ "$BUCKET_REGION" = "None" ] || [ "$BUCKET_REGION" = "null" ]; then
  # Either us-east-1 or the bucket doesn't exist — distinguish via head-bucket.
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    BUCKET_REGION="us-east-1"
  else
    echo "Error: bucket '$BUCKET' not found." >&2
    echo "Deploy it first: ./scripts/deploy-worlds-bucket.sh [region]" >&2
    exit 1
  fi
fi

INSTANCE_ID=$(aws cloudformation describe-stacks \
  --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text 2>/dev/null || true)
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "Error: stack '$STACK_NAME' not found in $REGION." >&2
  exit 1
fi

ORIGINAL_STATE=$(aws ec2 describe-instances \
  --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)

WAS_STOPPED=false
case "$ORIGINAL_STATE" in
  running)
    ;;
  stopped)
    WAS_STOPPED=true
    echo "Instance is stopped — starting it temporarily for the backup..."
    aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
      --output text --query 'StartingInstances[0].CurrentState.Name' >/dev/null
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
    echo -n "Waiting for SSM agent to come online"
    PING=""
    for i in $(seq 1 60); do
      PING=$(aws ssm describe-instance-information \
        --region "$REGION" \
        --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null || echo "")
      if [ "$PING" = "Online" ]; then echo " ready."; break; fi
      echo -n "."
      sleep 5
    done
    if [ "$PING" != "Online" ]; then
      echo ""
      echo "Error: SSM agent did not come online within 5 minutes." >&2
      exit 1
    fi
    ;;
  *)
    echo "Error: instance is '$ORIGINAL_STATE' (need 'running' or 'stopped')." >&2
    exit 1
    ;;
esac

RESTART_MC=true
if [ "$WAS_STOPPED" = "true" ]; then
  RESTART_MC=false
fi

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
S3_PREFIX_PATH="${S3_PREFIX}/snapshots/${TIMESTAMP}"

REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
cd /opt/minecraft
TARGETS=""
for d in world world_nether world_the_end maps; do
  [ -d "$d" ] && TARGETS="$TARGETS $d"
done
if [ -z "$TARGETS" ]; then
  echo "No world directories found at /opt/minecraft — has the server finished its first run?" >&2
  exit 1
fi
echo "Snapshotting:$TARGETS"
systemctl stop minecraft || true
for d in $TARGETS; do
  echo "Syncing $d -> s3://__BUCKET__/__PREFIX_PATH__/$d/"
  aws --region __BUCKET_REGION__ s3 sync "$d" "s3://__BUCKET__/__PREFIX_PATH__/$d/"
done
if [ "__RESTART_MC__" = "true" ]; then
  systemctl start minecraft
fi
echo "Snapshot complete."
REMOTE
)
REMOTE_SCRIPT="${REMOTE_SCRIPT//__BUCKET__/$BUCKET}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__PREFIX_PATH__/$S3_PREFIX_PATH}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__BUCKET_REGION__/$BUCKET_REGION}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__RESTART_MC__/$RESTART_MC}"

SCRIPT_B64=$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\n')

echo "Sending snapshot command to $INSTANCE_ID (bucket in $BUCKET_REGION)..."
COMMAND_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $SCRIPT_B64 | base64 -d | bash\"]}" \
  --query 'Command.CommandId' --output text)
echo "SSM CommandId: $COMMAND_ID"

echo -n "Waiting for completion (first snapshot is slowest; later runs are incremental)"
while true; do
  STATUS=$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Pending|InProgress|Delayed)
      echo -n "."
      sleep 5
      ;;
    Success)
      echo " done."
      break
      ;;
    *)
      echo ""
      echo "Snapshot failed (status: $STATUS)." >&2
      aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$COMMAND_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardErrorContent' --output text >&2
      if [ "$WAS_STOPPED" = "true" ]; then
        echo "Stopping instance again..." >&2
        aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
          --output text --query 'StoppingInstances[0].CurrentState.Name' >/dev/null || true
      fi
      exit 1
      ;;
  esac
done

if [ "$WAS_STOPPED" = "true" ]; then
  echo ""
  echo "Stopping instance again (it was stopped before the snapshot)..."
  aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --output text --query 'StoppingInstances[0].CurrentState.Name' >/dev/null
fi

echo ""
echo "Snapshot uploaded:"
echo "  s3://${BUCKET}/${S3_PREFIX_PATH}/"
echo ""
echo "Download locally (mirrors the full tree to ./snapshot-${TIMESTAMP}/):"
echo "  aws s3 sync s3://${BUCKET}/${S3_PREFIX_PATH}/ ./snapshot-${TIMESTAMP}/ --region $BUCKET_REGION"
echo ""
echo "List all snapshots for this version:"
echo "  aws s3 ls s3://${BUCKET}/${S3_PREFIX}/snapshots/ --region $BUCKET_REGION"

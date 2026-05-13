#!/usr/bin/env bash
# Archive the Minecraft world from the EBS data volume of a server stack
# and upload it to the shared S3 bucket. Works whether the instance is
# currently running or stopped — a stopped instance is started temporarily
# for the backup and stopped again afterwards.
#
# Backups land at:
#   s3://mc-worlds-<account>-<region>/<version>/worlds-YYYYMMDDTHHMMSSZ.tar.gz
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

INSTANCE_ID=$(aws cloudformation describe-stacks \
  --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text 2>/dev/null || true)
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "Error: stack '$STACK_NAME' not found in $REGION." >&2
  exit 1
fi

BUCKET=$(aws cloudformation describe-stacks \
  --region "$REGION" --stack-name "mc-worlds-bucket" \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
  --output text 2>/dev/null || true)
if [ -z "$BUCKET" ] || [ "$BUCKET" = "None" ]; then
  echo "Error: worlds bucket stack 'mc-worlds-bucket' not found in $REGION." >&2
  echo "Deploy it first: ./scripts/deploy-worlds-bucket.sh $REGION" >&2
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

# If we started the instance ourselves, leave Minecraft stopped after backup —
# we are going to stop the instance again anyway.
RESTART_MC=true
if [ "$WAS_STOPPED" = "true" ]; then
  RESTART_MC=false
fi

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
S3_KEY="${S3_PREFIX}/worlds-${TIMESTAMP}.tar.gz"

# Script that runs on the instance via SSM. Placeholders are substituted below;
# bash variables inside use $TARGETS etc. which are expanded on the instance, not locally.
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
echo "Archiving:$TARGETS"
systemctl stop minecraft || true
tar czf /tmp/worlds.tar.gz $TARGETS
echo "Uploading to s3://__BUCKET__/__KEY__"
aws --region __REGION__ s3 cp /tmp/worlds.tar.gz s3://__BUCKET__/__KEY__
rm -f /tmp/worlds.tar.gz
if [ "__RESTART_MC__" = "true" ]; then
  systemctl start minecraft
fi
echo "Backup complete."
REMOTE
)
REMOTE_SCRIPT="${REMOTE_SCRIPT//__BUCKET__/$BUCKET}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__KEY__/$S3_KEY}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__REGION__/$REGION}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__RESTART_MC__/$RESTART_MC}"

SCRIPT_B64=$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\n')

echo "Sending backup command to $INSTANCE_ID..."
COMMAND_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"echo $SCRIPT_B64 | base64 -d | bash\"]}" \
  --query 'Command.CommandId' --output text)
echo "SSM CommandId: $COMMAND_ID"

echo -n "Waiting for completion (may take a few minutes)"
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
      echo "Backup failed (status: $STATUS)." >&2
      echo "stderr from the instance:" >&2
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
  echo "Stopping instance again (it was stopped before the backup)..."
  aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --output text --query 'StoppingInstances[0].CurrentState.Name' >/dev/null
fi

echo ""
echo "Backup uploaded:"
echo "  s3://${BUCKET}/${S3_KEY}"
echo ""
echo "Download locally with:"
echo "  aws s3 cp s3://${BUCKET}/${S3_KEY} ./worlds-${TIMESTAMP}.tar.gz"
echo ""
echo "List all backups for this version:"
echo "  aws s3 ls s3://${BUCKET}/${S3_PREFIX}/"

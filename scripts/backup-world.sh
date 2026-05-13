#!/usr/bin/env bash
# Archive the Minecraft world from the EBS data volume of a running server
# and upload it to the shared S3 bucket.
#
# The server is briefly stopped during the archive to ensure a consistent snapshot,
# then restarted automatically. Backups land at:
#   s3://mc-worlds-<account>-<region>/<version>/worlds-YYYYMMDDTHHMMSSZ.tar.gz
#
# Prerequisites:
#   - deploy-worlds-bucket.sh has been run (creates the bucket)
#   - The target server stack has been deployed and the instance is running
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

STATE=$(aws ec2 describe-instances \
  --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)
if [ "$STATE" != "running" ]; then
  echo "Error: instance is '$STATE'. Start it first:" >&2
  echo "  ./scripts/server-start.sh $TARGET $REGION" >&2
  exit 1
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
systemctl start minecraft
echo "Backup complete."
REMOTE
)
REMOTE_SCRIPT="${REMOTE_SCRIPT//__BUCKET__/$BUCKET}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__KEY__/$S3_KEY}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__REGION__/$REGION}"

# Base64 the whole script so SSM gets one cleanly-quoted command line
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
      exit 1
      ;;
  esac
done

echo ""
echo "Backup uploaded:"
echo "  s3://${BUCKET}/${S3_KEY}"
echo ""
echo "Download locally with:"
echo "  aws s3 cp s3://${BUCKET}/${S3_KEY} ./worlds-${TIMESTAMP}.tar.gz"
echo ""
echo "List all backups for this version:"
echo "  aws s3 ls s3://${BUCKET}/${S3_PREFIX}/"

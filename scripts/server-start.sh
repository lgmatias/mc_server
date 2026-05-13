#!/usr/bin/env bash
# Start the EC2 instance for a Minecraft server.
#
# For vanilla stacks (mc-X-Y-Z): after the instance is up, replace the local
# world with s3://mc-worlds-<account>/<version>/world.tar.gz (if it exists),
# then start the minecraft service. This is how you "load" a different world
# — upload a new world.tar.gz to S3 and re-run this script.
#
# For PGM: after the instance is up, sync s3://mc-worlds-<account>/pgm-maps/
# into /opt/minecraft/maps/ (additive; does not delete local maps), then
# start the minecraft service.
#
# If the worlds bucket doesn't exist yet (first deploy with no backup), the
# instance just starts with whatever's on the data volume.
#
# Usage: ./server-start.sh <minecraft-version|pgm> [region]
#
# Examples:
#   ./server-start.sh 1.20.4
#   ./server-start.sh pgm

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

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="mc-worlds-${ACCOUNT_ID}"
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" \
  --query 'LocationConstraint' --output text 2>/dev/null || echo "")
if [ -z "$BUCKET_REGION" ] || [ "$BUCKET_REGION" = "None" ] || [ "$BUCKET_REGION" = "null" ]; then
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    BUCKET_REGION=us-east-1
  else
    echo "Note: worlds bucket '$BUCKET' not found — instance will start with whatever is on the data volume." >&2
    BUCKET=""
  fi
fi

STATE=$(aws ec2 describe-instances \
  --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)

if [ "$STATE" != "running" ]; then
  echo "Starting instance $INSTANCE_ID..."
  aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --output text --query 'StartingInstances[0].CurrentState.Name' >/dev/null
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
fi

echo -n "Waiting for SSM agent"
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
  echo "Warning: SSM agent did not come online within 5 minutes — skipping S3 sync." >&2
  BUCKET=""
fi

if [ -n "$BUCKET" ]; then
  if [ "$IS_PGM" = "true" ]; then
    echo "Mirroring PGM maps from s3://$BUCKET/pgm-maps/..."
    REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
systemctl stop minecraft || true
mkdir -p /opt/minecraft/maps
echo "Syncing maps from s3://__BUCKET__/pgm-maps/ (S3 is the source of truth)..."
aws --region __BUCKET_REGION__ s3 sync s3://__BUCKET__/pgm-maps/ /opt/minecraft/maps/ --delete
chown -R minecraft:minecraft /opt/minecraft/maps
systemctl start minecraft
echo "Start complete."
REMOTE
)
  else
    echo "Loading world from s3://$BUCKET/$TARGET/world.tar.gz (if it exists)..."
    REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
cd /opt/minecraft
systemctl stop minecraft || true
if aws --region __BUCKET_REGION__ s3 ls s3://__BUCKET__/__VERSION__/world.tar.gz >/dev/null 2>&1; then
  echo "Downloading world from S3..."
  aws --region __BUCKET_REGION__ s3 cp s3://__BUCKET__/__VERSION__/world.tar.gz /tmp/world.tar.gz
  rm -rf world world_nether world_the_end
  tar xzf /tmp/world.tar.gz -C /opt/minecraft/
  chown -R minecraft:minecraft /opt/minecraft/world /opt/minecraft/world_nether /opt/minecraft/world_the_end 2>/dev/null || true
  rm -f /tmp/world.tar.gz
  echo "World loaded from S3."
else
  echo "No world.tar.gz in s3://__BUCKET__/__VERSION__/ — using local world or generating fresh."
fi
systemctl start minecraft
echo "Start complete."
REMOTE
)
  fi

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

  echo -n "Waiting for load"
  while true; do
    SS=$(aws ssm get-command-invocation \
      --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text 2>/dev/null || echo Pending)
    case "$SS" in
      Pending|InProgress|Delayed) echo -n "."; sleep 5 ;;
      Success) echo " done."; break ;;
      *)
        echo ""
        echo "Load failed (status: $SS)." >&2
        aws ssm get-command-invocation \
          --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
          --query 'StandardErrorContent' --output text >&2 || true
        break
        ;;
    esac
  done
fi

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo ""
echo "Server is up."
echo "Public IP: $PUBLIC_IP (port 25565)"
echo "Allow ~30 seconds for Minecraft to finish loading the world."

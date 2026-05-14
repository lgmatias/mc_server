#!/usr/bin/env bash
# Start the EC2 instance for a Minecraft server.
#
# For vanilla stacks (mc-X-Y-Z): world sync from S3 happens automatically on
# the instance via the mc-pull-world.service systemd unit, which runs once at
# boot before minecraft.service. This script just starts the instance — the
# sync and Minecraft startup happen on the instance itself. To "load" a
# different world, upload a new world tree to s3://mc-worlds-<account>/<version>/
# and reboot the instance (or restart minecraft.service after restarting
# mc-pull-world.service).
#
# For PGM: after the instance is up, sync s3://mc-worlds-<account>/pgm-maps/
# into /opt/minecraft/maps/ (additive; does not delete local maps) via SSM,
# then start the minecraft service.
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
  echo "Warning: SSM agent did not come online within 5 minutes." >&2
fi

# PGM still uses SSM-based remote sync for maps. Vanilla's world sync is now
# handled on the instance by mc-pull-world.service (a oneshot systemd unit that
# runs before minecraft.service on every boot) — nothing for us to do here.
if [ "$IS_PGM" = "true" ] && [ -n "$BUCKET" ] && [ "$PING" = "Online" ]; then
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
  REMOTE_SCRIPT="${REMOTE_SCRIPT//__BUCKET__/$BUCKET}"
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
echo "Instance is up."
echo "Public IP: $PUBLIC_IP (port 25565)"
if [ "$IS_PGM" = "false" ]; then
  echo ""
  echo "Vanilla world sync runs on the instance via mc-pull-world.service."
  echo "Watch progress:"
  echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
  echo "  sudo journalctl -u mc-pull-world -u minecraft -f"
fi
echo ""
echo "Allow ~30 seconds for Minecraft to finish loading the world."

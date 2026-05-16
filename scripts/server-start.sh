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
# DNS: after the instance is up, this script points the mc.weighted.click A
# record (Route 53) at the instance's current public IP, so players connect by
# hostname. The instance gets a fresh ephemeral IP on every start, so the record
# is refreshed on each launch. Before repointing, it checks whether the record's
# current IP belongs to a RUNNING instance in any region — if so, another server
# is live on the hostname and the record is left alone. --no-ip skips the DNS
# update entirely.
#
# Usage: ./server-start.sh <minecraft-version|pgm> [region] [--no-ip]
#
# Examples:
#   ./server-start.sh 1.20.4
#   ./server-start.sh pgm
#   ./server-start.sh 1.20.4 us-west-2 --no-ip

set -euo pipefail

NO_IP=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-ip) NO_IP=true; shift ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

TARGET="${POSITIONAL[0]:?Usage: $0 <minecraft-version|pgm> [region] [--no-ip]}"
REGION="${POSITIONAL[1]:-us-east-1}"

if [ "$TARGET" = "pgm" ]; then
  STACK_NAME="pgm"
  IS_PGM=true
else
  STACK_NAME="mc-$(echo "$TARGET" | tr '._' '-')"
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

# Point the mc.weighted.click A record at this instance's current public IP so
# players can connect by hostname. The hosted zone is discovered by name, so
# nothing but the record name is hardcoded.
#
#   --no-ip            skip the DNS update entirely.
#   in-use protection  if the record currently points at an IP held by a
#                      RUNNING instance in any region, another server is live on
#                      the hostname — leave the record alone rather than hijack.
# Non-fatal: a DNS failure warns but does not abort — the server is already up.
DNS_RECORD="mc.weighted.click"
DNS_ZONE_NAME="weighted.click"
DNS_OK=false
if [ "$NO_IP" = "true" ]; then
  echo "--no-ip set — leaving the $DNS_RECORD A record unchanged."
elif [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
  echo "Warning: instance has no public IP — skipping DNS update." >&2
else
  ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DNS_ZONE_NAME" \
    --query "HostedZones[?Name=='${DNS_ZONE_NAME}.'].Id | [0]" --output text 2>/dev/null || echo "")
  if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
    echo "Warning: no Route 53 hosted zone for '$DNS_ZONE_NAME' — skipping DNS update." >&2
  else
    CURRENT_IP=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${DNS_RECORD}.' && Type=='A'] | [0].ResourceRecords[0].Value" \
      --output text 2>/dev/null || echo "")
    # If the record points somewhere other than us, check every region for a
    # running instance still holding that IP before we overwrite it.
    DNS_HOLDER=""
    DNS_HOLDER_REGION=""
    if [ -n "$CURRENT_IP" ] && [ "$CURRENT_IP" != "None" ] && [ "$CURRENT_IP" != "$PUBLIC_IP" ]; then
      for SCAN_REGION in $(aws ec2 describe-regions --query 'Regions[*].RegionName' --output text 2>/dev/null || echo ""); do
        DNS_HOLDER=$(aws ec2 describe-instances --region "$SCAN_REGION" \
          --filters "Name=ip-address,Values=$CURRENT_IP" "Name=instance-state-name,Values=running" \
          --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "")
        if [ -n "$DNS_HOLDER" ] && [ "$DNS_HOLDER" != "None" ]; then
          DNS_HOLDER_REGION="$SCAN_REGION"
          break
        fi
        DNS_HOLDER=""
      done
    fi
    if [ -n "$DNS_HOLDER" ]; then
      echo "Warning: $DNS_RECORD is in use by running instance $DNS_HOLDER" >&2
      echo "  in $DNS_HOLDER_REGION (IP $CURRENT_IP) — leaving the record unchanged." >&2
      echo "  Connect to this server directly at $PUBLIC_IP, or stop that instance first." >&2
    elif [ "$CURRENT_IP" = "$PUBLIC_IP" ]; then
      echo "$DNS_RECORD already points at this instance ($PUBLIC_IP)."
      DNS_OK=true
    else
      echo "Pointing $DNS_RECORD at $PUBLIC_IP..."
      CHANGE_BATCH=$(cat <<JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"$DNS_RECORD","Type":"A","TTL":60,"ResourceRecords":[{"Value":"$PUBLIC_IP"}]}}]}
JSON
)
      if aws route53 change-resource-record-sets \
           --hosted-zone-id "$ZONE_ID" --change-batch "$CHANGE_BATCH" \
           --query 'ChangeInfo.Id' --output text >/dev/null 2>&1; then
        DNS_OK=true
      else
        echo "Warning: DNS update failed (check Route 53 permissions)." >&2
      fi
    fi
  fi
fi

echo ""
echo "Instance is up."
echo "Public IP: $PUBLIC_IP (port 25565)"
if [ "$DNS_OK" = "true" ]; then
  echo "Hostname:  $DNS_RECORD"
fi
if [ "$IS_PGM" = "false" ]; then
  echo ""
  echo "Vanilla world sync runs on the instance via mc-pull-world.service."
  echo "Watch progress:"
  echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
  echo "  sudo journalctl -u mc-pull-world -u minecraft -f"
fi
echo ""
echo "Allow ~30 seconds for Minecraft to finish loading the world."

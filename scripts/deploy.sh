#!/usr/bin/env bash
# Deploy or update a Minecraft server stack. Two flavors share this one script,
# selected by the first argument:
#
#   - Vanilla: pass a Minecraft version (e.g. 1.20.4). One stack per version
#     per region; stack name is derived from the version (1.20.4 -> mc-1-20-4).
#     World data is restored from S3 on every boot via mc-pull-world.service
#     (see cloudformation/mc-server.yml UserData).
#   - PGM:     pass 'pgm'. Stack name is fixed at 'pgm'; maps come from
#     s3://mc-worlds-<acct>/pgm-maps/ on every boot (UserData syncs them via
#     --delete), so a fresh deploy in any region picks up the same map set.
#
# To "move" a vanilla server to a new region:
#   1. ./server-stop.sh <ver> <old-region>    # pushes world to s3://mc-worlds-<acct>/<ver>/
#   2. ./deploy.sh <ver> <type> <size> <new-region>   # fresh stack in new region,
#      mc-pull-world syncs world down on boot. After the new stack is up, deploy.sh
#      scans every region for any same-named stack and auto-terminates it (stack +
#      retained EBS volume) so the old region's volume stops billing. If the old
#      instance is still running (i.e. server-stop.sh was skipped), the auto-
#      terminate is skipped for that region — see warning in output.
#
# DNS: after the deploy, this script points the mc.weighted.click A record
# (Route 53) at the new instance's public IP, so players connect by hostname —
# unless --no-ip is passed, or the record is already in use by a running
# instance in some region (in which case it is left alone).
#
# Usage: ./deploy.sh <minecraft-version|pgm> [instance-type] [volume-size-gb] [region] [--no-ip]
#
# Examples:
#   ./deploy.sh 1.20.4
#   ./deploy.sh 1.20.4 t3.large
#   ./deploy.sh 1.16.5 t3.medium 30 us-west-2
#   ./deploy.sh pgm
#   ./deploy.sh pgm t3.large
#   ./deploy.sh pgm t3.medium 30 us-west-2
#   ./deploy.sh 1.20.4 t3.large 20 us-west-2 --no-ip

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

TARGET="${POSITIONAL[0]:?Usage: $0 <minecraft-version|pgm> [instance-type] [volume-size] [region] [--no-ip]}"
REGION="${POSITIONAL[3]:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$TARGET" = "pgm" ]; then
  IS_PGM=true
  STACK_NAME="pgm"
  TEMPLATE="$SCRIPT_DIR/../cloudformation/pgm-server.yml"
  TARGET_DESC="PGM 1.8.9"
else
  IS_PGM=false
  MC_VERSION="$TARGET"
  # tr maps '.' and '_' → '-': CFN stack names allow only alphanumerics and
  # hyphens, and alpha version ids (e.g. a1.1.2_01) contain an underscore.
  STACK_NAME="mc-$(echo "$MC_VERSION" | tr '._' '-')"
  TEMPLATE="$SCRIPT_DIR/../cloudformation/mc-server.yml"
  TARGET_DESC="Minecraft $MC_VERSION"
fi

# Default-resolution policy for optional args ($2 InstanceType, $3 VolumeSize):
# if the stack already exists, preserve its current parameter value unless the
# caller explicitly passes a new one. This avoids two footguns:
#   - VolumeSize: EBS rejects ModifyVolume calls that decrease size, and CFN
#     traps the stack in UPDATE_ROLLBACK_FAILED. Hardcoding a default of 20
#     would silently attempt a shrink against any grown volume.
#   - InstanceType: CFN allows InstanceType changes via instance replacement,
#     so hardcoding a default of t3.medium would silently downgrade a t3.large
#     on every "default" re-invocation.
# For a fresh deploy (no existing stack) both fall back to the canonical
# defaults (t3.medium / 20 GB).
if [ -n "${POSITIONAL[1]:-}" ]; then
  INSTANCE_TYPE="${POSITIONAL[1]}"
  INSTANCE_TYPE_SRC="argument"
else
  EXISTING_TYPE=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
    --query "Stacks[0].Parameters[?ParameterKey=='InstanceType'].ParameterValue | [0]" \
    --output text 2>/dev/null || echo "")
  if [ -z "$EXISTING_TYPE" ] || [ "$EXISTING_TYPE" = "None" ]; then
    INSTANCE_TYPE=t3.medium
    INSTANCE_TYPE_SRC="default (fresh deploy)"
  else
    INSTANCE_TYPE="$EXISTING_TYPE"
    INSTANCE_TYPE_SRC="preserved from existing stack"
  fi
fi

if [ -n "${POSITIONAL[2]:-}" ]; then
  VOLUME_SIZE="${POSITIONAL[2]}"
  VOLUME_SIZE_SRC="argument"
else
  EXISTING_SIZE=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
    --query "Stacks[0].Parameters[?ParameterKey=='VolumeSize'].ParameterValue | [0]" \
    --output text 2>/dev/null || echo "")
  if [ -z "$EXISTING_SIZE" ] || [ "$EXISTING_SIZE" = "None" ]; then
    VOLUME_SIZE=20
    VOLUME_SIZE_SRC="default (fresh deploy)"
  else
    VOLUME_SIZE="$EXISTING_SIZE"
    VOLUME_SIZE_SRC="preserved from existing stack"
  fi
fi

# The vanilla template (mc-server.yml) is architecture-aware: it picks the AMI
# from InstanceArchitecture and sizes the JVM heap from ServerMemoryMB. Derive
# both from the chosen instance type so any family — x86 or Graviton/ARM —
# works. PGM is left x86/t3-class, so this is vanilla-only.
INSTANCE_ARCH=x86_64
SERVER_MEMORY=2048
if [ "$IS_PGM" != "true" ]; then
  IT_INFO=$(aws ec2 describe-instance-types --region "$REGION" --instance-types "$INSTANCE_TYPE" \
    --query 'InstanceTypes[0].[ProcessorInfo.SupportedArchitectures[0],MemoryInfo.SizeInMiB]' \
    --output text 2>/dev/null || echo "")
  case "$(echo "$IT_INFO" | awk '{print $1}')" in
    *arm64*) INSTANCE_ARCH=arm64 ;;
    *)       INSTANCE_ARCH=x86_64 ;;
  esac
  IT_MEM=$(echo "$IT_INFO" | awk '{print $2}')
  if [ -n "$IT_MEM" ] && [ "$IT_MEM" != "None" ]; then
    # Heap = instance RAM minus ~1 GB for the OS (matches the template guidance).
    SERVER_MEMORY=$((IT_MEM - 1024))
    [ "$SERVER_MEMORY" -lt 512 ] && SERVER_MEMORY=512
  fi
fi

echo "Target: $TARGET_DESC as stack '$STACK_NAME' in $REGION"
echo "  Instance type: $INSTANCE_TYPE  ($INSTANCE_TYPE_SRC)"
if [ "$IS_PGM" != "true" ]; then
  echo "  Architecture:  $INSTANCE_ARCH  (auto-detected)"
  echo "  Server heap:   ${SERVER_MEMORY} MB  (instance RAM minus ~1 GB for the OS)"
fi
echo "  Volume size:   ${VOLUME_SIZE} GB  ($VOLUME_SIZE_SRC)"
echo ""

# pgm-server.yml does not declare a MinecraftVersion parameter (PGM is pinned
# to 1.8.9 inside the template), so omit it from the override set for PGM.
if [ "$IS_PGM" = "true" ]; then
  PARAMS=(
    "InstanceType=$INSTANCE_TYPE"
    "VolumeSize=$VOLUME_SIZE"
  )
else
  PARAMS=(
    "MinecraftVersion=$MC_VERSION"
    "InstanceType=$INSTANCE_TYPE"
    "InstanceArchitecture=$INSTANCE_ARCH"
    "VolumeSize=$VOLUME_SIZE"
    "ServerMemoryMB=$SERVER_MEMORY"
  )
fi

# Pre-deploy: scan every other region for a stack with the same name. After the
# new deploy succeeds we'll terminate them so cross-region migrations don't
# leave the old region's stopped instance + retained EBS volume billing forever.
# Safety: if any stale stack's instance is still running, the world may have
# unsaved changes that aren't on S3 yet — skip that region with a warning and
# let the user resolve manually (server-stop.sh to push+stop, then re-run, or
# terminate.sh directly if the data is disposable).
echo "Scanning other regions for stale '$STACK_NAME' stacks..."
ALL_REGIONS=$(aws ec2 describe-regions --query 'Regions[*].RegionName' --output text)
STALE_REGIONS=()
RUNNING_STALE=()
for SCAN_REGION in $ALL_REGIONS; do
  [ "$SCAN_REGION" = "$REGION" ] && continue
  if ! aws cloudformation describe-stacks --region "$SCAN_REGION" --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    continue
  fi
  STALE_IID=$(aws cloudformation describe-stacks --region "$SCAN_REGION" --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]" \
    --output text 2>/dev/null || echo "")
  STALE_STATE=""
  if [ -n "$STALE_IID" ] && [ "$STALE_IID" != "None" ]; then
    STALE_STATE=$(aws ec2 describe-instances --region "$SCAN_REGION" --instance-ids "$STALE_IID" \
      --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null || echo "")
  fi
  echo "  Found '$STACK_NAME' in $SCAN_REGION (instance ${STALE_IID:-?}, state: ${STALE_STATE:-unknown})"
  if [ "$STALE_STATE" = "running" ]; then
    RUNNING_STALE+=("$SCAN_REGION")
  else
    STALE_REGIONS+=("$SCAN_REGION")
  fi
done
if [ ${#STALE_REGIONS[@]} -eq 0 ] && [ ${#RUNNING_STALE[@]} -eq 0 ]; then
  echo "  None."
fi
echo ""

echo "Deploying stack..."
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides "${PARAMS[@]}" \
  --no-fail-on-empty-changeset

# For vanilla, ensure the version's prefix exists in the worlds bucket.
# server-start.sh treats S3 as the source of truth for world files; this marker
# makes the prefix visible in the console and confirms the bucket is reachable
# from this region. Non-fatal if the bucket doesn't exist yet — user can deploy
# it later. PGM pulls maps from a fixed pgm-maps/ prefix, not a per-version
# one, so no marker work is needed for PGM.
if [ "$IS_PGM" != "true" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  WORLDS_BUCKET="mc-worlds-${ACCOUNT_ID}"
  WORLDS_BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$WORLDS_BUCKET" \
    --query 'LocationConstraint' --output text 2>/dev/null || echo "")
  if [ -z "$WORLDS_BUCKET_REGION" ] || [ "$WORLDS_BUCKET_REGION" = "None" ] || [ "$WORLDS_BUCKET_REGION" = "null" ]; then
    if aws s3api head-bucket --bucket "$WORLDS_BUCKET" 2>/dev/null; then
      WORLDS_BUCKET_REGION=us-east-1
    else
      WORLDS_BUCKET=""
    fi
  fi
  if [ -n "$WORLDS_BUCKET" ]; then
    # Create a zero-byte world/ folder marker so a user browsing the S3 console
    # sees exactly where this version's world data goes. Vanilla Java Edition
    # stores nether (DIM-1) and end (DIM1) as subdirs of world/, so a single
    # marker covers all dimensions. mc-pull-world on the instance filters Size>0,
    # so this marker doesn't count as "S3 has content" — an empty marker still
    # triggers a fresh world regen on boot.
    HAS_CONTENT=$(aws --region "$WORLDS_BUCKET_REGION" s3api list-objects-v2 \
      --bucket "$WORLDS_BUCKET" --prefix "${MC_VERSION}/world/" \
      --query 'Contents[?Size > `0`].Key | [0]' --output text 2>/dev/null || echo "")
    MARKER_EXISTS=$(aws --region "$WORLDS_BUCKET_REGION" s3api head-object \
      --bucket "$WORLDS_BUCKET" --key "${MC_VERSION}/world/" \
      --query 'ContentLength' --output text 2>/dev/null || echo "")
    if [ -z "$HAS_CONTENT" ] || [ "$HAS_CONTENT" = "None" ]; then
      if [ -z "$MARKER_EXISTS" ]; then
        echo "Creating s3://$WORLDS_BUCKET/$MC_VERSION/world/ folder marker..."
        aws --region "$WORLDS_BUCKET_REGION" s3api put-object \
          --bucket "$WORLDS_BUCKET" --key "${MC_VERSION}/world/" >/dev/null
      fi
    fi
  else
    echo "Note: worlds bucket 'mc-worlds-${ACCOUNT_ID}' not found — run ./scripts/deploy-worlds-bucket.sh to create it."
  fi
fi

echo ""
echo "Stack deployed. Server details:"
aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table

# Point the mc.weighted.click A record at the instance's current public IP. On
# a fresh deploy the instance is running with a public IP; on an update of a
# stopped stack there's no public IP yet — ./server-start.sh will set DNS then.
# The CFN PublicIP output is captured at create time, so query the live IP.
#
#   --no-ip            skip the DNS update entirely.
#   in-use protection  if the record currently points at an IP held by a
#                      RUNNING instance in any region, another server is live on
#                      the hostname — leave the record alone rather than hijack.
# Non-fatal: a DNS failure warns but does not abort — the deploy already succeeded.
DNS_RECORD="mc.weighted.click"
DNS_ZONE_NAME="weighted.click"
INSTANCE_ID=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]" --output text 2>/dev/null || echo "")
LIVE_IP=""
if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
  LIVE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || echo "")
fi
if [ "$NO_IP" = "true" ]; then
  echo ""
  echo "--no-ip set — leaving the $DNS_RECORD A record unchanged."
  if [ -n "$LIVE_IP" ] && [ "$LIVE_IP" != "None" ]; then
    echo "Current public IP: $LIVE_IP (port 25565)"
  fi
elif [ -z "$LIVE_IP" ] || [ "$LIVE_IP" = "None" ]; then
  echo ""
  echo "Instance has no public IP yet (stopped?) — $DNS_RECORD will be set on next ./server-start.sh."
else
  echo ""
  echo "Current public IP: $LIVE_IP (port 25565)"
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
    if [ -n "$CURRENT_IP" ] && [ "$CURRENT_IP" != "None" ] && [ "$CURRENT_IP" != "$LIVE_IP" ]; then
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
      echo "  Connect to this server directly at $LIVE_IP, or stop that instance first." >&2
    elif [ "$CURRENT_IP" = "$LIVE_IP" ]; then
      echo "$DNS_RECORD already points at this instance ($LIVE_IP)."
    else
      echo "Pointing $DNS_RECORD at $LIVE_IP..."
      CHANGE_BATCH=$(cat <<JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"$DNS_RECORD","Type":"A","TTL":60,"ResourceRecords":[{"Value":"$LIVE_IP"}]}}]}
JSON
)
      if aws route53 change-resource-record-sets \
           --hosted-zone-id "$ZONE_ID" --change-batch "$CHANGE_BATCH" \
           --query 'ChangeInfo.Id' --output text >/dev/null 2>&1; then
        echo "DNS updated: $DNS_RECORD -> $LIVE_IP (TTL 60s; allow up to ~1 min to propagate)."
      else
        echo "Warning: DNS update failed (check Route 53 permissions)." >&2
      fi
    fi
  fi
fi

# Tear down stale same-named stacks in other regions (discovered pre-deploy).
# Doing this AFTER the new deploy succeeds means: if the new deploy fails for
# any reason, the old stack survives as recovery; only once we know the new
# region is up do we delete the old region's volume.
if [ ${#STALE_REGIONS[@]} -gt 0 ]; then
  echo ""
  echo "Terminating stale stack(s) to free retained EBS volume(s)..."
  for STALE_REGION in "${STALE_REGIONS[@]}"; do
    echo ""
    echo "--- ./terminate.sh $TARGET $STALE_REGION --yes ---"
    "$SCRIPT_DIR/terminate.sh" "$TARGET" "$STALE_REGION" --yes
  done
fi
if [ ${#RUNNING_STALE[@]} -gt 0 ]; then
  echo ""
  echo "WARNING: '$STACK_NAME' is still RUNNING in: ${RUNNING_STALE[*]}" >&2
  echo "  Auto-terminate skipped — world may have unsaved changes not yet in S3." >&2
  echo "  To clean up: ./server-stop.sh $TARGET <region>   (push world + stop), then" >&2
  echo "               ./terminate.sh $TARGET <region>     (delete stack + EBS volume)" >&2
fi

echo ""
if [ "$IS_PGM" = "true" ]; then
  echo "Next steps:"
  echo "  1. Allow ~3 minutes for UserData to finish: Java install, jar downloads,"
  echo "     and the initial clone of https://github.com/PGMDev/Maps (5 default maps)."
  echo "  2. Connect at the PublicIP above on port 25565 — default maps load automatically."
  echo "  3. To add custom maps: upload map folders to s3://mc-worlds-<account>/pgm-maps/"
  echo "     and restart: sudo systemctl restart minecraft"
  echo "     Each map folder must contain a map.xml — see https://pgm.dev/docs/map/"
else
  echo "First deploy: allow ~2 minutes for the server jar to download and start."
  echo "Connect to the instance via Session Manager — see the SessionManagerConsole URL above."
fi

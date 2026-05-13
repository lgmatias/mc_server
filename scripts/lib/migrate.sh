# Shared helpers for cross-region migration and bucket cleanup.
# Sourced by deploy.sh, deploy-pgm.sh, and cleanup.sh — not executed directly.

# State variables set by prepare_migration_if_needed (read by deploy script,
# then by finalize_migration_if_needed).
MIGRATION_SOURCE_REGION=""
MIGRATION_SOURCE_STACK=""
MIGRATION_SOURCE_VOLUME=""
MIGRATION_SOURCE_SNAPSHOT=""
MIGRATION_DEST_SNAPSHOT=""
MIGRATION_VOLUME_SIZE=""

# Returns 0 if the named CFN stack exists in the given region.
stack_exists_in_region() {
  local region=$1
  local stack=$2
  aws cloudformation describe-stacks --region "$region" --stack-name "$stack" \
    --query 'Stacks[0].StackName' --output text >/dev/null 2>&1
}

# Echoes the first region (other than $1) where the stack $2 exists.
# Empty string + return 1 if not found anywhere.
find_source_region() {
  local target=$1
  local stack=$2
  local regions="${SCAN_REGIONS:-}"
  if [ -z "$regions" ]; then
    regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)
  fi
  for r in $regions; do
    [ "$r" = "$target" ] && continue
    if stack_exists_in_region "$r" "$stack"; then
      echo "$r"
      return 0
    fi
  done
  return 1
}

# Stop the Minecraft service on the source instance (if running) so the snapshot
# captures a consistent on-disk state. Silent no-op if the instance is stopped.
quiesce_source_minecraft() {
  local region=$1
  local instance=$2

  local state
  state=$(aws ec2 describe-instances --region "$region" --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")

  if [ "$state" != "running" ]; then
    return 0
  fi

  echo "  Stopping Minecraft on source instance for a consistent snapshot..."
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$region" --instance-ids "$instance" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["systemctl stop minecraft || true","sync"]' \
    --query 'Command.CommandId' --output text 2>/dev/null) || return 0

  for i in $(seq 1 60); do
    local status
    status=$(aws ssm get-command-invocation --region "$region" \
      --command-id "$cmd_id" --instance-id "$instance" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
    case "$status" in
      Pending|InProgress|Delayed) sleep 2 ;;
      Success) return 0 ;;
      *) return 0 ;;
    esac
  done
}

# If the stack exists only in another region, snapshot its volume and copy the
# snapshot to the target region. Does NOT delete the old stack yet — that
# happens in finalize_migration_if_needed after the new stack succeeds.
prepare_migration_if_needed() {
  local target_region=$1
  local stack=$2

  if stack_exists_in_region "$target_region" "$stack"; then
    echo "Stack '$stack' already exists in $target_region — updating in place."
    return 0
  fi

  echo "Searching other regions for an existing '$stack' stack..."
  local src
  src=$(find_source_region "$target_region" "$stack" || true)
  if [ -z "$src" ]; then
    echo "No existing '$stack' found anywhere — creating fresh."
    return 0
  fi

  echo ""
  echo "Found '$stack' in $src."
  echo "Migration plan: snapshot the data volume in $src, copy to $target_region,"
  echo "deploy the new stack, then delete the old stack and orphaned volume in $src."
  read -p "Proceed? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Aborted by user."; exit 1 ;;
  esac

  MIGRATION_SOURCE_REGION="$src"
  MIGRATION_SOURCE_STACK="$stack"

  MIGRATION_SOURCE_VOLUME=$(aws cloudformation describe-stacks \
    --region "$src" --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='DataVolumeId'].OutputValue" \
    --output text)
  MIGRATION_VOLUME_SIZE=$(aws ec2 describe-volumes --region "$src" \
    --volume-ids "$MIGRATION_SOURCE_VOLUME" \
    --query 'Volumes[0].Size' --output text)

  local src_instance
  src_instance=$(aws cloudformation describe-stacks \
    --region "$src" --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
    --output text)
  quiesce_source_minecraft "$src" "$src_instance"

  echo "  Snapshotting source volume $MIGRATION_SOURCE_VOLUME (${MIGRATION_VOLUME_SIZE} GB)..."
  MIGRATION_SOURCE_SNAPSHOT=$(aws ec2 create-snapshot --region "$src" \
    --volume-id "$MIGRATION_SOURCE_VOLUME" \
    --description "Migration: $stack from $src to $target_region" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Purpose,Value=mc-migration},{Key=Stack,Value=$stack}]" \
    --query 'SnapshotId' --output text)
  aws ec2 wait snapshot-completed --region "$src" --snapshot-ids "$MIGRATION_SOURCE_SNAPSHOT"

  echo "  Copying snapshot to $target_region (this may take several minutes)..."
  MIGRATION_DEST_SNAPSHOT=$(aws ec2 copy-snapshot --region "$target_region" \
    --source-region "$src" --source-snapshot-id "$MIGRATION_SOURCE_SNAPSHOT" \
    --description "Migrated: $stack from $src" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Purpose,Value=mc-migration},{Key=Stack,Value=$stack}]" \
    --query 'SnapshotId' --output text)
  aws ec2 wait snapshot-completed --region "$target_region" --snapshot-ids "$MIGRATION_DEST_SNAPSHOT"
  echo "  Snapshot ready in $target_region: $MIGRATION_DEST_SNAPSHOT"
}

# After the new stack is verified deployed, delete the old stack, its orphaned
# volume, and both migration snapshots.
finalize_migration_if_needed() {
  local dest_region=$1
  [ -z "$MIGRATION_SOURCE_REGION" ] && return 0

  local src="$MIGRATION_SOURCE_REGION"
  local stack="$MIGRATION_SOURCE_STACK"

  echo ""
  echo "Finalizing migration — cleaning up old resources in $src..."

  echo "  Deleting old stack '$stack'..."
  aws cloudformation delete-stack --region "$src" --stack-name "$stack"
  aws cloudformation wait stack-delete-complete --region "$src" --stack-name "$stack" || true

  if [ -n "$MIGRATION_SOURCE_VOLUME" ]; then
    echo "  Deleting orphaned volume $MIGRATION_SOURCE_VOLUME..."
    aws ec2 delete-volume --region "$src" --volume-id "$MIGRATION_SOURCE_VOLUME" 2>/dev/null \
      || echo "    (could not delete — may need manual cleanup)"
  fi

  if [ -n "$MIGRATION_SOURCE_SNAPSHOT" ]; then
    aws ec2 delete-snapshot --region "$src" --snapshot-id "$MIGRATION_SOURCE_SNAPSHOT" 2>/dev/null || true
  fi
  if [ -n "$MIGRATION_DEST_SNAPSHOT" ]; then
    aws ec2 delete-snapshot --region "$dest_region" --snapshot-id "$MIGRATION_DEST_SNAPSHOT" 2>/dev/null || true
  fi

  echo "  Migration complete."
}

# Empty a versioned S3 bucket — deletes every object version and delete marker.
# Required before delete-bucket because the bucket has versioning enabled.
empty_versioned_bucket() {
  local bucket=$1
  local region=$2
  local tmp
  tmp=$(mktemp)

  while true; do
    aws s3api list-object-versions --bucket "$bucket" --region "$region" --max-items 1000 \
      --output json --query 'Versions[].{Key:Key,VersionId:VersionId}' > "$tmp" 2>/dev/null || break
    local count
    count=$(python3 -c "import json; d=json.load(open('$tmp')); print(len(d) if d else 0)" 2>/dev/null || echo 0)
    [ "$count" = "0" ] && break
    python3 -c "import json; d=json.load(open('$tmp')); json.dump({'Objects':d,'Quiet':True}, open('$tmp','w'))"
    aws s3api delete-objects --bucket "$bucket" --region "$region" --delete "file://$tmp" >/dev/null
  done

  while true; do
    aws s3api list-object-versions --bucket "$bucket" --region "$region" --max-items 1000 \
      --output json --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' > "$tmp" 2>/dev/null || break
    local count
    count=$(python3 -c "import json; d=json.load(open('$tmp')); print(len(d) if d else 0)" 2>/dev/null || echo 0)
    [ "$count" = "0" ] && break
    python3 -c "import json; d=json.load(open('$tmp')); json.dump({'Objects':d,'Quiet':True}, open('$tmp','w'))"
    aws s3api delete-objects --bucket "$bucket" --region "$region" --delete "file://$tmp" >/dev/null
  done

  rm -f "$tmp"
}

# Resolve the region a bucket lives in (handles us-east-1 which returns null).
bucket_region() {
  local bucket=$1
  local loc
  loc=$(aws s3api get-bucket-location --bucket "$bucket" \
    --query 'LocationConstraint' --output text 2>/dev/null || echo "")
  if [ -z "$loc" ] || [ "$loc" = "None" ] || [ "$loc" = "null" ]; then
    echo "us-east-1"
  else
    echo "$loc"
  fi
}

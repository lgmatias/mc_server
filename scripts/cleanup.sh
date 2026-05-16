#!/usr/bin/env bash
# Tear down every resource this project may have created across all regions:
#   - mc-* and pgm CloudFormation stacks (and their orphaned data EBS volumes)
#   - any legacy snapshots tagged Purpose=mc-migration (from when cross-region
#     migration used EBS snapshots — that path is gone, but old snapshots may
#     still exist on the account)
#   - the mc-worlds-bucket CFN stack and the S3 bucket it manages
#     (handles BOTH the old per-region pattern mc-worlds-<acct>-<region>
#      and the new shared pattern mc-worlds-<acct>)
#
# Requires confirmation. Usage: ./cleanup.sh
# Optional: SCAN_REGIONS="us-east-1 eu-west-1" ./cleanup.sh   # limit scan

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "This will permanently delete, across all AWS regions in account $ACCOUNT_ID:"
echo "  - Every mc-* and pgm CloudFormation stack"
echo "  - The EBS data volumes they created (your worlds)"
echo "  - Any 'mc-migration' tagged snapshots"
echo "  - The mc-worlds-bucket stack(s) and the S3 bucket(s) they manage"
echo "    (including ALL backup objects and versions)"
echo ""
read -p "Type DELETE to confirm: " ans
if [ "$ans" != "DELETE" ]; then
  echo "Aborted."
  exit 1
fi

REGIONS="${SCAN_REGIONS:-$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)}"

# Track bucket names we encounter so we can delete each only once at the end.
BUCKETS_SEEN=""

for region in $REGIONS; do
  echo ""
  echo "=== $region ==="

  STACKS=$(aws cloudformation list-stacks --region "$region" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE CREATE_FAILED ROLLBACK_COMPLETE \
    --query "StackSummaries[?starts_with(StackName, 'mc-') || StackName == 'pgm'].StackName" \
    --output text 2>/dev/null || echo "")

  for stack in $STACKS; do
    if [ "$stack" = "mc-worlds-bucket" ]; then
      # Collect the bucket name from outputs (covers both old/new naming).
      BKT=$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack" \
        --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
        --output text 2>/dev/null || echo "")
      if [ -n "$BKT" ] && [ "$BKT" != "None" ]; then
        BUCKETS_SEEN="$BUCKETS_SEEN $BKT"
      fi
      continue
    fi

    echo "  Deleting stack: $stack"
    VOL=$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack" \
      --query "Stacks[0].Outputs[?OutputKey=='DataVolumeId'].OutputValue" \
      --output text 2>/dev/null || echo "")
    aws cloudformation delete-stack --region "$region" --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --region "$region" --stack-name "$stack" || true

    if [ -n "$VOL" ] && [ "$VOL" != "None" ]; then
      echo "    Deleting orphaned data volume: $VOL"
      aws ec2 delete-volume --region "$region" --volume-id "$VOL" 2>/dev/null \
        || echo "    (volume may already be gone)"
    fi
  done

  SNAPS=$(aws ec2 describe-snapshots --region "$region" --owner-ids self \
    --filters "Name=tag:Purpose,Values=mc-migration" \
    --query 'Snapshots[].SnapshotId' --output text 2>/dev/null || echo "")
  for snap in $SNAPS; do
    echo "  Deleting migration snapshot: $snap"
    aws ec2 delete-snapshot --region "$region" --snapshot-id "$snap" 2>/dev/null || true
  done
done

# Also try the predicted shared bucket name in case the stack is gone but the bucket lingers.
PREDICTED="mc-worlds-${ACCOUNT_ID}"
if aws s3api head-bucket --bucket "$PREDICTED" 2>/dev/null; then
  BUCKETS_SEEN="$BUCKETS_SEEN $PREDICTED"
fi

# Dedupe
BUCKETS_SEEN=$(printf '%s\n' $BUCKETS_SEEN | sort -u | tr '\n' ' ')

if [ -n "${BUCKETS_SEEN// /}" ]; then
  echo ""
  echo "=== S3 buckets ==="
  for bkt in $BUCKETS_SEEN; do
    if ! aws s3api head-bucket --bucket "$bkt" 2>/dev/null; then
      echo "  '$bkt' not found, skipping."
      continue
    fi
    BREG=$(bucket_region "$bkt")
    echo "  Emptying '$bkt' (in $BREG) — all object versions and delete markers..."
    empty_versioned_bucket "$bkt" "$BREG"
    echo "  Deleting bucket '$bkt'..."
    aws s3api delete-bucket --bucket "$bkt" --region "$BREG" 2>/dev/null \
      || echo "    (could not delete; check the AWS console)"
  done
fi

# Now delete the worlds-bucket CFN stack(s) — they succeed because the retained
# bucket is already gone.
echo ""
echo "=== worlds-bucket CFN stacks ==="
for region in $REGIONS; do
  if aws cloudformation describe-stacks --region "$region" --stack-name "mc-worlds-bucket" >/dev/null 2>&1; then
    echo "  Deleting mc-worlds-bucket stack in $region..."
    aws cloudformation delete-stack --region "$region" --stack-name "mc-worlds-bucket"
    aws cloudformation wait stack-delete-complete --region "$region" --stack-name "mc-worlds-bucket" || true
  fi
done

echo ""
echo "Cleanup complete."

#!/usr/bin/env bash
# Deploy the single shared S3 bucket used by backup-world.sh.
# Run this once for your AWS account, in whichever region you want the bucket
# to live in. The bucket name is mc-worlds-<account-id> (no region suffix), so
# servers in any region can write to the same bucket.
#
# On first setup this also populates s3://<bucket>/server-jars/ with archived
# alpha/beta Minecraft server jars. Mojang's version manifest has no
# `downloads.server` entry for alpha/beta versions, so mc-server.yml's UserData
# falls back to pulling s3://<bucket>/server-jars/<version>.jar for them. The
# staging step is idempotent — skipped if server-jars/ is already populated.
#
# Usage: ./deploy-worlds-bucket.sh [region]

set -euo pipefail

REGION="${1:-us-east-1}"
STACK_NAME="mc-worlds-bucket"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../cloudformation/worlds-bucket.yml"

# Dropbox archive of alpha/beta server jars (folder share; dl=1 → whole-folder
# zip). Each entry below maps an archive path to its Mojang manifest id so the
# S3 key matches what mc-server.yml UserData expects: server-jars/<id>.jar.
JAR_ARCHIVE_URL="https://www.dropbox.com/scl/fo/b7fgnxpb5nem1z99e2gbh/AFZYmwZX52MS59P-sh1KtQA?rlkey=vnw8u30dx0640n4pjqofjt6lk&dl=1"

echo "Deploying worlds-bucket stack '$STACK_NAME' in $REGION..."

aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --no-fail-on-empty-changeset

echo ""
aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table

# --- Stage alpha/beta server jars into server-jars/ -------------------------
# Only the alpha/beta versions that map to a real Mojang manifest id are staged
# (prereleases / test builds in the archive aren't deployable and are omitted).
BUCKET=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue | [0]" --output text)

EXISTING_JAR=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix 'server-jars/' \
  --query 'Contents[?Size > `0`].Key | [0]' --output text 2>/dev/null || echo "")

echo ""
if [ -n "$EXISTING_JAR" ] && [ "$EXISTING_JAR" != "None" ]; then
  echo "server-jars/ already populated — skipping alpha/beta jar staging."
elif ! command -v unzip >/dev/null 2>&1; then
  echo "WARNING: 'unzip' not found — cannot stage alpha/beta server jars." >&2
  echo "  Install unzip and re-run, or upload jars manually to s3://$BUCKET/server-jars/." >&2
else
  echo "Populating s3://$BUCKET/server-jars/ with archived alpha/beta server jars..."
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  echo "  Downloading jar archive (~520 MB)..."
  if ! curl -fsSL -o "$TMP/jars.zip" "$JAR_ARCHIVE_URL"; then
    echo "WARNING: jar archive download failed — server-jars/ not populated." >&2
  elif ! unzip -q "$TMP/jars.zip" -d "$TMP/x"; then
    echo "WARNING: could not unzip the jar archive — server-jars/ not populated." >&2
  else
    STAGED=0
    while IFS='|' read -r relpath id; do
      [ -z "${id:-}" ] && continue
      if [ ! -f "$TMP/x/$relpath" ]; then
        echo "  WARNING: archive missing '$relpath' — skipped $id" >&2
        continue
      fi
      if aws s3 cp "$TMP/x/$relpath" "s3://$BUCKET/server-jars/$id.jar" --only-show-errors; then
        STAGED=$((STAGED + 1))
      else
        echo "  WARNING: upload failed for $id" >&2
      fi
    done <<'JARMAP'
Alpha/minecraft_server 1.0.17_02.jar|a1.0.17_02
Alpha/minecraft_server 1.0.17_04.jar|a1.0.17_04
Alpha/minecraft_server 1.1.0.jar|a1.1.0
Alpha/minecraft_server 1.1.2_01.jar|a1.1.2_01
Alpha/minecraft_server 1.2.0.jar|a1.2.0
Alpha/minecraft_server 1.2.0_02.jar|a1.2.0_02
Alpha/minecraft_server 1.2.2B.jar|a1.2.2b
Alpha/minecraft_server 1.2.3.jar|a1.2.3
Alpha/minecraft_server 1.2.3_04 - Confirm.jar|a1.2.3_04
Alpha/minecraft_server 1.2.4_01.jar|a1.2.4_01
Alpha/minecraft_server 1.2.5.jar|a1.2.5
Alpha/minecraft_server 1.2.6.jar|a1.2.6
Beta 1.0/minecraft_server 1.0.jar|b1.0
Beta 1.0/minecraft_server 1.0.2.jar|b1.0.2
Beta 1.1/minecraft_server 1.1_02.jar|b1.1_02
Beta 1.2/minecraft_server 1.2.jar|b1.2
Beta 1.2/minecraft_server 1.2_01.jar|b1.2_01
Beta 1.2/minecraft_server 1.2_02.jar|b1.2_02
Beta 1.3/minecraft_server 1.3_01.jar|b1.3_01
Beta 1.4/minecraft_server 1.4 CONFIRM.jar|b1.4
Beta 1.4/minecraft_server 1.4_01.jar|b1.4_01
Beta 1.5/minecraft_server 1.5.jar|b1.5
Beta 1.6/minecraft_server 1.6.jar|b1.6
Beta 1.6/minecraft_server 1.6.6.jar|b1.6.6
Beta 1.7/minecraft_server 1.7.jar|b1.7
Beta 1.7/minecraft_server 1.7.3.jar|b1.7.3
JARMAP
    echo "  Staged $STAGED alpha/beta jars to s3://$BUCKET/server-jars/"
  fi
  rm -rf "$TMP"
  trap - EXIT
fi
# ----------------------------------------------------------------------------

echo ""
echo "Bucket has DeletionPolicy=Retain — deleting this stack will not delete backups."
echo "Note: data uploads from EC2 in other regions cross AWS regions (~\$0.02/GB transfer cost)."

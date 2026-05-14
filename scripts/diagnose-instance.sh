#!/usr/bin/env bash
# Run a diagnostic snapshot on an mc-server / pgm-server instance via SSM.
#
# Usage: ./diagnose-instance.sh <instance-id> [region]
#
# Captures: UserData setup log, systemd status, journal, file tree, the
# generated configs, Java version, and the latest server log — everything
# needed to diagnose why a freshly deployed server isn't accepting connections.

set -euo pipefail

INSTANCE_ID="${1:?Usage: $0 <instance-id> [region]}"
REGION="${2:-us-east-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_FILE="$SCRIPT_DIR/diagnose-instance.params.json"

# Git Bash on Windows reports POSIX-style paths (/c/...) but the AWS CLI on
# Windows expects native paths (C:\...). Translate when running under MSYS.
if command -v cygpath >/dev/null 2>&1; then
  PARAMS_FILE_NATIVE="$(cygpath -w "$PARAMS_FILE")"
else
  PARAMS_FILE_NATIVE="$PARAMS_FILE"
fi

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --cli-input-json "file://$PARAMS_FILE_NATIVE" \
  --region "$REGION" \
  --query "Command.CommandId" --output text)

echo "Command ID: $CMD_ID"
echo "Waiting for completion..."

for i in $(seq 1 30); do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  if [ "$STATUS" = "Success" ] || [ "$STATUS" = "Failed" ] || [ "$STATUS" = "TimedOut" ]; then
    break
  fi
  sleep 2
done

echo ""
echo "--- STDOUT ---"
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION" \
  --query "StandardOutputContent" --output text

echo ""
echo "--- STDERR ---"
aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION" \
  --query "StandardErrorContent" --output text

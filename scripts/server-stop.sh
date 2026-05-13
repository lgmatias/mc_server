#!/usr/bin/env bash
# Stop the EC2 instance for a Minecraft server.
# The instance is stopped (not terminated), so the EBS data volume is preserved.
# You are not billed for compute while the instance is stopped.
#
# Usage: ./server-stop.sh <minecraft-version|pgm> [region]
#
# Examples:
#   ./server-stop.sh 1.20.4
#   ./server-stop.sh pgm

set -euo pipefail

TARGET="${1:?Usage: $0 <minecraft-version|pgm> [region]}"
REGION="${2:-us-east-1}"

if [ "$TARGET" = "pgm" ]; then
  STACK_NAME="pgm"
else
  STACK_NAME="mc-$(echo "$TARGET" | tr '.' '-')"
fi

INSTANCE_ID=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "Error: could not find InstanceId output in stack '$STACK_NAME'" >&2
  exit 1
fi

echo "Stopping instance $INSTANCE_ID (stack: $STACK_NAME)..."
echo "The Minecraft process receives SIGTERM and saves the world before shutdown."
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --output text --query 'StoppingInstances[0].CurrentState.Name'

echo "Waiting for instance to reach stopped state..."
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "Instance stopped. Note: the public IP will change on next start unless an Elastic IP is attached."

#!/usr/bin/env bash
# Start the EC2 instance for a Minecraft server.
# The systemd minecraft.service starts automatically when the instance boots.
#
# Usage: ./server-start.sh <minecraft-version|pgm> [region]
#
# Examples:
#   ./server-start.sh 1.20.4       # starts the mc-1-20-4 stack instance
#   ./server-start.sh pgm          # starts the pgm stack instance

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

echo "Starting instance $INSTANCE_ID (stack: $STACK_NAME)..."
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --output text --query 'StartingInstances[0].CurrentState.Name'

echo "Waiting for instance to reach running state..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Instance is running."
echo "Public IP: $PUBLIC_IP"
echo "Allow ~60 seconds for the Minecraft process to finish loading."

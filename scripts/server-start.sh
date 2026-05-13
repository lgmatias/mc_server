#!/usr/bin/env bash
# Start the EC2 instance for a Minecraft server stack.
# The systemd minecraft.service starts automatically on boot.
#
# Usage: ./server-start.sh <stack-name> [region]

set -euo pipefail

STACK_NAME="${1:?Usage: $0 <stack-name> [region]}"
REGION="${2:-us-east-1}"

INSTANCE_ID=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
  --output text)

if [ -z "$INSTANCE_ID" ]; then
  echo "Error: could not find InstanceId output in stack '$STACK_NAME'" >&2
  exit 1
fi

echo "Starting instance $INSTANCE_ID (stack: $STACK_NAME)..."
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --output text --query 'StartingInstances[0].CurrentState.Name'

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

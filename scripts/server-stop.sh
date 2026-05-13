#!/usr/bin/env bash
# Stop the EC2 instance for a Minecraft server stack.
# The instance is stopped (not terminated), so EBS data and the IP allocation are preserved.
# You are not billed for compute while the instance is stopped.
#
# Usage: ./server-stop.sh <stack-name> [region]

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

echo "Stopping instance $INSTANCE_ID (stack: $STACK_NAME)..."
echo "The Minecraft process receives SIGTERM and saves the world before the OS shuts down."
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --output text --query 'StoppingInstances[0].CurrentState.Name'

echo "Waiting for instance to reach stopped state..."
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"

echo "Instance stopped. Note: the public IP will change on next start unless an Elastic IP is attached."

#!/usr/bin/env bash
# Open an SSM port-forward tunnel through the SkySpot jumpbox to a private model
# endpoint, so you can curl the model from your laptop.
#
#   laptop:LOCAL_PORT  --SSM-->  jumpbox  --VPC-->  MODEL_IP:REMOTE_PORT
#
# Usage:
#   ./connect.sh <jumpbox-instance-id> <model-private-ip> [remote-port] [local-port] [region]
#
# Example:
#   ./connect.sh i-0abc123 10.10.1.42 8000 8000 eu-north-1
#   # in another terminal:
#   curl http://localhost:8000/v1/models
#
# Requirements: AWS CLI v2 + the session-manager-plugin installed locally, and
# credentials for the account/region where the jumpbox lives.
set -euo pipefail

INSTANCE_ID="${1:?jumpbox instance id required (see: terraform output instance_id)}"
MODEL_IP="${2:?model private IP required (see: sky serve status / sky status --ip)}"
REMOTE_PORT="${3:-8000}"
LOCAL_PORT="${4:-8000}"
REGION="${5:-${AWS_REGION:-eu-north-1}}"

echo "Tunneling localhost:${LOCAL_PORT} -> ${MODEL_IP}:${REMOTE_PORT} via ${INSTANCE_ID} (${REGION})"
echo "Leave this running; use the model from another terminal. Ctrl-C to close."

exec aws ssm start-session \
  --region "${REGION}" \
  --target "${INSTANCE_ID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${MODEL_IP}\"],\"portNumber\":[\"${REMOTE_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"

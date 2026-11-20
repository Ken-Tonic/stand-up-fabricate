#!/usr/bin/env bash
set -euo pipefail

# tear-down-fabricate.sh
# Terminates the EC2 instance and cleans up all resources created by stand-up-fabricate.sh.
#
# Usage:
#   ./tear-down-fabricate.sh [instance-name]
#
# Default instance name is "fabricate" (matches stand-up-fabricate.sh default).

INSTANCE_NAME="${1:-${INSTANCE_NAME:-fabricate}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/.fabricate-state-${INSTANCE_NAME}.env"

if [[ -f "$STATE_FILE" ]]; then
  echo "==> Loading state from $STATE_FILE..."
  # shellcheck source=/dev/null
  source "$STATE_FILE"
else
  echo "WARNING: No state file found at $STATE_FILE"
  echo "         Falling back to environment variables or defaults."
  AWS_REGION="${AWS_REGION:-us-east-1}"
  INSTANCE_ID="${INSTANCE_ID:-}"
  SG_ID="${SG_ID:-}"
  KEY_NAME="${KEY_NAME:-${INSTANCE_NAME}-key}"
  SSH_KEY_FILE="${SSH_KEY_FILE:-${SCRIPT_DIR}/${KEY_NAME}.pem}"
fi

if [[ -z "${AWS_REGION:-}" ]]; then
  echo "ERROR: AWS_REGION is not set." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Terminate EC2 instance
# ---------------------------------------------------------------------------
if [[ -n "${INSTANCE_ID:-}" ]]; then
  echo "==> Terminating EC2 instance '$INSTANCE_ID'..."
  if aws ec2 terminate-instances \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID" \
      > /dev/null 2>/tmp/term-err; then
    echo "==> Waiting for instance to terminate..."
    aws ec2 wait instance-terminated \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID"
    echo "    Instance terminated."
  elif grep -q "InvalidInstanceID.NotFound" /tmp/term-err; then
    echo "    Instance not found — already terminated."
  else
    cat /tmp/term-err >&2; exit 1
  fi
else
  echo "WARNING: INSTANCE_ID not set, skipping instance termination."
fi

# ---------------------------------------------------------------------------
# Delete security group
# ---------------------------------------------------------------------------
if [[ -n "${SG_ID:-}" ]]; then
  echo "==> Deleting security group '$SG_ID'..."
  # ENIs can persist briefly after instance termination; retry on DependencyViolation.
  for i in $(seq 1 24); do
    if aws ec2 delete-security-group \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" 2>/tmp/sg-delete-err; then
      echo "    Security group deleted."
      break
    fi
    if grep -q "InvalidGroup.NotFound" /tmp/sg-delete-err; then
      echo "    Security group already deleted."
      break
    elif grep -q "DependencyViolation" /tmp/sg-delete-err; then
      [[ "$i" -eq 24 ]] && { cat /tmp/sg-delete-err >&2; exit 1; }
      echo "    Waiting for network interfaces to detach... ($i/24)"
      sleep 5
    else
      cat /tmp/sg-delete-err >&2
      exit 1
    fi
  done
else
  echo "WARNING: SG_ID not set, skipping security group deletion."
fi

# ---------------------------------------------------------------------------
# Delete key pair
# ---------------------------------------------------------------------------
if [[ -n "${KEY_NAME:-}" ]]; then
  echo "==> Deleting key pair '$KEY_NAME'..."
  if aws ec2 delete-key-pair \
      --region "$AWS_REGION" \
      --key-name "$KEY_NAME" 2>/tmp/kp-delete-err; then
    echo "    Key pair deleted."
  elif grep -q "InvalidKeyPair.NotFound" /tmp/kp-delete-err; then
    echo "    Key pair already deleted."
  else
    cat /tmp/kp-delete-err >&2; exit 1
  fi

  if [[ -f "${SSH_KEY_FILE:-}" ]]; then
    rm -f "$SSH_KEY_FILE"
    echo "    Local key file removed: $SSH_KEY_FILE"
  fi
else
  echo "WARNING: KEY_NAME not set, skipping key pair deletion."
fi

# ---------------------------------------------------------------------------
# Clean up state file
# ---------------------------------------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
  rm "$STATE_FILE"
  echo "==> State file removed."
fi

echo ""
echo "========================================"
echo "  Teardown complete for: $INSTANCE_NAME"
echo "========================================"

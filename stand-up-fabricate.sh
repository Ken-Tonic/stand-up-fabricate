#!/usr/bin/env bash
set -euo pipefail

# stand-up-fabricate.sh
# Spins up an EC2 instance running Fabricate (self-hosted) via Docker Compose.
# Template .env reference: https://github.com/TonicAI/fabricate_docker_compose/blob/main/.template.env
#
# Usage:
#   ./stand-up-fabricate.sh
#
# Override defaults via environment variables:
#   INSTANCE_NAME=my-fab INSTANCE_TYPE=t3.xlarge ADMIN_EMAIL=me@example.com ./stand-up-fabricate.sh
#
# Optional — set an LLM API key before running (required by the setup wizard):
#   export ANTHROPIC_API_KEY=sk-ant-...

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
INSTANCE_NAME="${INSTANCE_NAME:-fabricate}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.large}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@fabricate.local}"
SG_NAME="${SG_NAME:-${INSTANCE_NAME}-sg}"
KEY_NAME="${KEY_NAME:-${INSTANCE_NAME}-key}"
DISK_SIZE_GB="${DISK_SIZE_GB:-40}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_KEY_FILE="${SCRIPT_DIR}/${KEY_NAME}.pem"
STATE_FILE="${SCRIPT_DIR}/.fabricate-state-${INSTANCE_NAME}.env"

# ---------------------------------------------------------------------------
# Load credentials from local .env
# ---------------------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
  echo "ERROR: .env file not found at ${SCRIPT_DIR}/.env" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/.env"
: "${QUAY_IO_USER:?QUAY_IO_USER not set in .env}"
: "${QUAY_IO_PASSWORD:?QUAY_IO_PASSWORD not set in .env}"
: "${FABRICATE_LICENSE:?FABRICATE_LICENSE not set in .env}"
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set in .env}"

# ---------------------------------------------------------------------------
# Generate random credentials for Postgres and Redis
# ---------------------------------------------------------------------------
DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
REDIS_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)

# ---------------------------------------------------------------------------
# VPC Selection
# ---------------------------------------------------------------------------
if [[ -n "${VPC_ID:-}" ]]; then
  echo "==> Using pre-configured VPC: $VPC_ID"
else
  echo "==> Fetching available VPCs in $AWS_REGION..."
  VPC_JSON=$(aws ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --query "Vpcs[*].{Id:VpcId,CIDR:CidrBlock,Default:IsDefault,Name:Tags[?Key=='Name']|[0].Value}" \
    --output json)

  VPC_COUNT=$(echo "$VPC_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

  if [[ "$VPC_COUNT" -eq 0 ]]; then
    echo "ERROR: No VPCs found in region $AWS_REGION." >&2
    exit 1
  fi

  echo ""
  echo "  #  VPC ID           CIDR            Default  Name"
  echo "  -- ---------------- --------------- -------- ----"
  echo "$VPC_JSON" | python3 -c "
import sys, json
vpcs = json.load(sys.stdin)
for i, v in enumerate(vpcs, 1):
    default = 'yes' if v['Default'] else 'no'
    name = v['Name'] or ''
    print(f\"  {i:<2} {v['Id']:<16} {v['CIDR']:<15} {default:<8} {name}\")
"
  echo ""

  if [[ "$VPC_COUNT" -eq 1 ]]; then
    read -rp "Use the only available VPC? [Y/n] " confirm
    if [[ "${confirm,,}" == "n" ]]; then
      echo "Aborted." && exit 0
    fi
    CHOICE=1
  else
    while true; do
      read -rp "Select a VPC [1-${VPC_COUNT}]: " CHOICE
      if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [[ "$CHOICE" -ge 1 ]] && [[ "$CHOICE" -le "$VPC_COUNT" ]]; then
        break
      fi
      echo "  Please enter a number between 1 and $VPC_COUNT."
    done
  fi

  VPC_ID=$(echo "$VPC_JSON" | python3 -c "
import sys, json
vpcs = json.load(sys.stdin)
print(vpcs[${CHOICE}-1]['Id'])
")
  echo "    Selected VPC: $VPC_ID"
fi

# ---------------------------------------------------------------------------
# Find a public subnet (one with an internet gateway route)
# ---------------------------------------------------------------------------
echo "==> Finding a public subnet in $VPC_ID..."
PUBLIC_SUBNET_ID=$(aws ec2 describe-route-tables \
  --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[?Routes[?GatewayId && starts_with(GatewayId,'igw-') && DestinationCidrBlock=='0.0.0.0/0']].Associations[*].SubnetId" \
  --output json | python3 -c "
import sys, json
data = json.load(sys.stdin)
ids = [sid for group in data for sid in group if sid]
print(ids[0] if ids else '')
")

if [[ -z "$PUBLIC_SUBNET_ID" ]]; then
  echo "ERROR: No public subnets (with internet gateway route) found in VPC $VPC_ID." >&2
  exit 1
fi
echo "    Using subnet: $PUBLIC_SUBNET_ID"

# ---------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------
EXISTING_SG=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text)

if [[ "$EXISTING_SG" != "None" && -n "$EXISTING_SG" ]]; then
  echo "==> Security group '$SG_NAME' already exists, reusing ($EXISTING_SG)."
  SG_ID="$EXISTING_SG"
else
  echo "==> Creating security group '$SG_NAME'..."
  SG_ID=$(aws ec2 create-security-group \
    --region "$AWS_REGION" \
    --group-name "$SG_NAME" \
    --description "Fabricate instance security group for $INSTANCE_NAME" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" \
    --output text)
  echo "    Security Group: $SG_ID"

  aws ec2 create-tags \
    --region "$AWS_REGION" \
    --resources "$SG_ID" \
    --tags \
      "Key=Name,Value=${SG_NAME}" \
      "Key=tonic.ai/owner,Value=ken@tonic.ai" \
      "Key=tonic.ai/product,Value=sa"

  # SSH, HTTP, HTTPS, Fabricate app
  for PORT in 22 80 443 3000; do
    echo "    Authorizing inbound port $PORT from 0.0.0.0/0..."
    aws ec2 authorize-security-group-ingress \
      --region "$AWS_REGION" \
      --group-id "$SG_ID" \
      --protocol tcp \
      --port "$PORT" \
      --cidr "0.0.0.0/0" > /dev/null
  done
  echo "    Security group ready."
fi

# ---------------------------------------------------------------------------
# SSH key pair
# ---------------------------------------------------------------------------
if aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" > /dev/null 2>&1; then
  echo "==> Key pair '$KEY_NAME' already exists."
  if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "    WARNING: $SSH_KEY_FILE not found locally. SSH into the instance may fail."
  fi
else
  echo "==> Creating key pair '$KEY_NAME'..."
  aws ec2 create-key-pair \
    --region "$AWS_REGION" \
    --key-name "$KEY_NAME" \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=${KEY_NAME}},{Key=tonic.ai/owner,Value=ken@tonic.ai},{Key=tonic.ai/product,Value=sa}]" \
    --query "KeyMaterial" \
    --output text > "$SSH_KEY_FILE"
  chmod 600 "$SSH_KEY_FILE"
  echo "    Key saved to: $SSH_KEY_FILE"
fi

# ---------------------------------------------------------------------------
# Find latest Ubuntu 24.04 LTS AMI (Canonical owner: 099720109477)
# ---------------------------------------------------------------------------
echo "==> Finding latest Ubuntu 24.04 LTS AMI in $AWS_REGION..."
AMI_ID=$(aws ec2 describe-images \
  --region "$AWS_REGION" \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)
echo "    AMI: $AMI_ID"

# ---------------------------------------------------------------------------
# Check for an existing instance with the same name
# ---------------------------------------------------------------------------
echo "==> Checking for existing instance named '$INSTANCE_NAME'..."
EXISTING_INSTANCE=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters \
    "Name=tag:Name,Values=${INSTANCE_NAME}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text)

if [[ "$EXISTING_INSTANCE" != "None" && -n "$EXISTING_INSTANCE" ]]; then
  EXISTING_STATE=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$EXISTING_INSTANCE" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text)
  EXISTING_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$EXISTING_INSTANCE" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)
  echo ""
  echo "ERROR: An instance named '$INSTANCE_NAME' already exists." >&2
  echo "       Instance ID: $EXISTING_INSTANCE" >&2
  echo "       State:       $EXISTING_STATE" >&2
  echo "       Public IP:   ${EXISTING_IP:-none}" >&2
  echo "" >&2
  echo "       To use a different name: INSTANCE_NAME=my-fab ./stand-up-fabricate.sh" >&2
  echo "       To tear down first:      ./tear-down-fabricate.sh" >&2
  exit 1
fi
echo "    No existing instance found."

# ---------------------------------------------------------------------------
# Launch EC2 instance
# User data installs Docker on first boot via the official Docker apt repo.
# A sentinel file /tmp/docker-ready is written when installation completes.
# ---------------------------------------------------------------------------
echo "==> Launching EC2 instance ($INSTANCE_TYPE, Ubuntu 24.04)..."

USER_DATA_FILE=$(mktemp /tmp/fabricate-userdata.XXXXXX)
trap 'rm -f "$USER_DATA_FILE"' EXIT

cat > "$USER_DATA_FILE" <<'USERDATA'
#!/bin/bash
set -e
exec > /var/log/user-data.log 2>&1
echo "==> user-data started at $(date)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu
touch /tmp/docker-ready
echo "==> user-data completed at $(date)"
USERDATA

INSTANCE_ID=$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --associate-public-ip-address \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${DISK_SIZE_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --user-data "file://${USER_DATA_FILE}" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=tonic.ai/owner,Value=ken@tonic.ai},{Key=tonic.ai/product,Value=sa}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=tonic.ai/owner,Value=ken@tonic.ai},{Key=tonic.ai/product,Value=sa}]" \
  --query "Instances[0].InstanceId" \
  --output text)
echo "    Instance ID: $INSTANCE_ID"

# ---------------------------------------------------------------------------
# Wait for running state and get public IP
# ---------------------------------------------------------------------------
echo "==> Waiting for instance to enter 'running' state..."
aws ec2 wait instance-running \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)
echo "    Public IP: $PUBLIC_IP"

# ---------------------------------------------------------------------------
# Wait for SSH
# ---------------------------------------------------------------------------
echo "==> Waiting for SSH to become available (this may take a couple of minutes)..."
for i in $(seq 1 40); do
  if ssh -i "$SSH_KEY_FILE" \
      -o StrictHostKeyChecking=no \
      -o IdentitiesOnly=yes \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      "ubuntu@${PUBLIC_IP}" "echo ok" 2>/dev/null; then
    echo "    SSH ready."
    break
  fi
  [[ "$i" -eq 40 ]] && { echo "ERROR: SSH timed out after 10 minutes." >&2; exit 1; }
  echo "    Attempt $i/40, retrying in 15s..."
  sleep 15
done

# ---------------------------------------------------------------------------
# Wait for Docker (user-data runs asynchronously after boot)
# ---------------------------------------------------------------------------
echo "==> Waiting for Docker installation to complete (up to 15 min)..."
for i in $(seq 1 90); do
  if ssh -i "$SSH_KEY_FILE" \
      -o StrictHostKeyChecking=no \
      -o IdentitiesOnly=yes \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "ubuntu@${PUBLIC_IP}" \
      "test -f /tmp/docker-ready && sudo docker info > /dev/null 2>&1" 2>/dev/null; then
    echo "    Docker ready."
    break
  fi
  if [[ "$i" -eq 90 ]]; then
    echo "ERROR: Docker installation timed out after 15 minutes." >&2
    echo "       Check /var/log/user-data.log on the instance for details:" >&2
    ssh -i "$SSH_KEY_FILE" \
      -o StrictHostKeyChecking=no \
      -o IdentitiesOnly=yes \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "ubuntu@${PUBLIC_IP}" "tail -20 /var/log/user-data.log" 2>/dev/null || true
    exit 1
  fi
  # Every 30 seconds (every 3rd iteration), show the last line of the install log
  if (( i % 3 == 0 )); then
    LOG_TAIL=$(ssh -i "$SSH_KEY_FILE" \
      -o StrictHostKeyChecking=no \
      -o IdentitiesOnly=yes \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      "ubuntu@${PUBLIC_IP}" "tail -1 /var/log/user-data.log 2>/dev/null" 2>/dev/null || true)
    echo "    Waiting for Docker... ($i/90)${LOG_TAIL:+ — ${LOG_TAIL}}"
  else
    echo "    Waiting for Docker... ($i/90)"
  fi
  sleep 10
done

# ---------------------------------------------------------------------------
# Log in to quay.io, pull the main image, generate SECRET_KEY_BASE
# ---------------------------------------------------------------------------
echo "==> Authenticating with quay.io and pulling Fabricate image..."
ssh -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  "ubuntu@${PUBLIC_IP}" \
  "sudo docker login -u='${QUAY_IO_USER}' -p='${QUAY_IO_PASSWORD}' quay.io \
    && sudo docker pull quay.io/tonicai/fabricate:latest \
    && sudo docker pull quay.io/tonicai/fabricate-html-to-pdf-sidecar:latest" \
  2>&1 | grep -v "^WARNING"

echo "==> Generating SECRET_KEY_BASE..."
SECRET_KEY_BASE=$(ssh -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  "ubuntu@${PUBLIC_IP}" \
  "sudo docker run --rm quay.io/tonicai/fabricate:latest /fabricate/bin/rails secret 2>/dev/null | tail -1")

if [[ -z "$SECRET_KEY_BASE" ]]; then
  echo "ERROR: Failed to generate SECRET_KEY_BASE." >&2
  exit 1
fi
echo "    SECRET_KEY_BASE generated."

# ---------------------------------------------------------------------------
# Build config files locally, then SCP to instance
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d /tmp/fabricate-config.XXXXXX)
trap 'rm -rf "$TMP_DIR"; rm -f "$USER_DATA_FILE"' EXIT

# --- .env ---
cat > "${TMP_DIR}/.env" <<EOF
# Fabricate self-hosted configuration
# Reference: https://github.com/TonicAI/fabricate_docker_compose/blob/main/.template.env

SECRET_KEY_BASE=${SECRET_KEY_BASE}

AWS_REGION=${AWS_REGION}

# Use local disk storage (the Docker volume). The default in production.rb is
# "amazon" (S3), which requires FABRICATE_S3_BUCKET and fails at boot without it.
FABRICATE_STORAGE_SERVICE=local

FABRICATE_HOST=${PUBLIC_IP}
FABRICATE_PROTOCOL=http
FABRICATE_PORT=3000
FABRICATE_FORCE_SSL=false

FABRICATE_ADMIN_EMAIL=${ADMIN_EMAIL}

FABRICATE_DATABASE_USERNAME=fabricate
FABRICATE_DATABASE_PASSWORD=${DB_PASSWORD}
FABRICATE_DATABASE_NAME=fabricate_production
FABRICATE_DATABASE_HOST=db
FABRICATE_DATABASE_PORT=5432

FABRICATE_REDIS_PASSWORD=${REDIS_PASSWORD}
FABRICATE_REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379/0

FABRICATE_LICENSE_KEY=${FABRICATE_LICENSE}
EOF

if [[ -n "$ANTHROPIC_API_KEY" ]]; then
  cat >> "${TMP_DIR}/.env" <<EOF

FABRICATE_ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
FABRICATE_ANTHROPIC_BASE_URL=https://api.anthropic.com
EOF
fi

# --- docker-compose.yaml (single-quoted heredoc — no shell expansion) ---
cat > "${TMP_DIR}/docker-compose.yaml" <<'COMPOSEEOF'
networks:
  fabricate_internal:
    driver: bridge
  fabricate_internal_pdf:
    internal: true

volumes:
  fabricate_data:
  fabricate_local_storage:
  postgres_data:

services:
  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${FABRICATE_DATABASE_USERNAME}
      POSTGRES_PASSWORD: ${FABRICATE_DATABASE_PASSWORD}
      POSTGRES_DB: ${FABRICATE_DATABASE_NAME}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - fabricate_internal

  redis:
    image: 'redis:7.4.8'
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${FABRICATE_REDIS_PASSWORD}
    command: ["sh", "-c", "exec redis-server --requirepass \"$$REDIS_PASSWORD\""]
    networks:
      - fabricate_internal

  pdf-sidecar:
    image: 'quay.io/tonicai/fabricate-html-to-pdf-sidecar:latest'
    restart: unless-stopped
    cap_drop:
      - ALL
    read_only: true
    security_opt:
      - no-new-privileges:true
    mem_limit: 1024m
    environment:
      FABRICATE_PDF_PORT: ${FABRICATE_PDF_PORT:-3100}
    volumes:
      - type: tmpfs
        target: /tmp
        tmpfs:
          size: 536870912
      - type: tmpfs
        target: /dev/shm
        tmpfs:
          size: 268435456
    networks:
      - fabricate_internal_pdf

  web:
    image: 'quay.io/tonicai/fabricate:latest'
    restart: unless-stopped
    depends_on:
      db:
        condition: service_started
      redis:
        condition: service_started
      pdf-sidecar:
        condition: service_healthy
    ports:
      - '3000:3000'
    env_file:
      - .env
    environment:
      FABRICATE_PDF_HOST: pdf-sidecar
      FABRICATE_PDF_PORT: ${FABRICATE_PDF_PORT:-3100}
    cap_add:
      - SYS_PTRACE
    volumes:
      - fabricate_data:/fabricate/data
      - fabricate_local_storage:/fabricate/storage
    networks:
      - fabricate_internal
      - fabricate_internal_pdf

  worker:
    image: 'quay.io/tonicai/fabricate:latest'
    restart: unless-stopped
    command: ["bundle", "exec", "sidekiq", "-e", "production"]
    depends_on:
      db:
        condition: service_started
      redis:
        condition: service_started
      pdf-sidecar:
        condition: service_healthy
      web:
        condition: service_started
    env_file:
      - .env
    environment:
      FABRICATE_PDF_HOST: pdf-sidecar
      FABRICATE_PDF_PORT: ${FABRICATE_PDF_PORT:-3100}
    cap_add:
      - SYS_PTRACE
    volumes:
      - fabricate_data:/fabricate/data
      - fabricate_local_storage:/fabricate/storage
    networks:
      - fabricate_internal
      - fabricate_internal_pdf
COMPOSEEOF

# ---------------------------------------------------------------------------
# Upload config to instance
# ---------------------------------------------------------------------------
echo "==> Uploading configuration to instance..."
ssh -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  "ubuntu@${PUBLIC_IP}" "mkdir -p ~/fabricate"

scp -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  "${TMP_DIR}/.env" \
  "${TMP_DIR}/docker-compose.yaml" \
  "ubuntu@${PUBLIC_IP}:~/fabricate/"

# ---------------------------------------------------------------------------
# Start Fabricate
# ---------------------------------------------------------------------------
echo "==> Starting Fabricate services (docker compose up -d)..."
ssh -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  "ubuntu@${PUBLIC_IP}" \
  "cd ~/fabricate && sudo docker compose up -d"
echo "    Services started."

# ---------------------------------------------------------------------------
# Save state for tear-down
# ---------------------------------------------------------------------------
cat > "$STATE_FILE" <<EOF
INSTANCE_ID=${INSTANCE_ID}
INSTANCE_NAME=${INSTANCE_NAME}
SG_ID=${SG_ID}
KEY_NAME=${KEY_NAME}
SSH_KEY_FILE=${SSH_KEY_FILE}
AWS_REGION=${AWS_REGION}
PUBLIC_IP=${PUBLIC_IP}
EOF
echo "==> State saved to $STATE_FILE"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "  Fabricate Instance Ready"
echo "========================================"
echo "  Instance ID:  $INSTANCE_ID"
echo "  Public IP:    $PUBLIC_IP"
echo "  Fabricate:    http://${PUBLIC_IP}:3000"
echo "  Admin email:  $ADMIN_EMAIL"
echo "========================================"
echo ""
echo "To SSH in:"
echo "  ssh -i \"${SSH_KEY_FILE}\" -o IdentitiesOnly=yes ubuntu@${PUBLIC_IP}"
echo ""
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
  echo "NEXT: Add an LLM provider to ~/fabricate/.env on the instance, then:"
  echo "  sudo docker compose -f ~/fabricate/docker-compose.yaml up -d --force-recreate"
  echo ""
fi
echo "Complete setup at: http://${PUBLIC_IP}:3000"
echo "  1. Click 'Get Started'"
echo "  2. Run the compatibility check"
echo "  3. Enter your license key"
echo "  4. Configure telemetry"
echo "  5. Create your admin account (use ${ADMIN_EMAIL})"
echo ""

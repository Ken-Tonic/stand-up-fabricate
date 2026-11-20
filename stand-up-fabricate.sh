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
DISK_SIZE_GB="${DISK_SIZE_GB:-60}"
AUTO_SETUP_ADMIN="${AUTO_SETUP_ADMIN:-false}"
TAGS="${TAGS:-}"

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
: "${TAGS:?TAGS not set in .env (format: Key:Value,Key:Value)}"

# Parse TAGS="Key:Value,Key:Value" into the two formats AWS CLI expects.
# AWS_TAGS_KV  — space-separated "Key=k,Value=v" args for aws ec2 create-tags
# AWS_TAGS_JSON — comma-separated "{Key=k,Value=v}" fragment for --tag-specifications
AWS_TAGS_KV=""
AWS_TAGS_JSON=""
IFS=',' read -ra _TAG_PAIRS <<< "$TAGS"
for _pair in "${_TAG_PAIRS[@]}"; do
  _key="${_pair%%:*}"
  _val="${_pair#*:}"
  AWS_TAGS_KV+="Key=${_key},Value=${_val} "
  AWS_TAGS_JSON+="{Key=${_key},Value=${_val}},"
done
AWS_TAGS_KV="${AWS_TAGS_KV% }"
AWS_TAGS_JSON="${AWS_TAGS_JSON%,}"
unset _TAG_PAIRS _pair _key _val

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
    --tags "Key=Name,Value=${SG_NAME}" ${AWS_TAGS_KV}

  # SSH, HTTP, HTTPS (nginx handles all Fabricate traffic on 80/443)
  for PORT in 22 80 443; do
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
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=${KEY_NAME}},${AWS_TAGS_JSON}]" \
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
    "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},${AWS_TAGS_JSON}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=${INSTANCE_NAME}},${AWS_TAGS_JSON}]" \
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

# --- Email delivery ---
# Priority: custom SMTP > SES (opt-in) > Mailhog (default)
if [[ -n "${FABRICATE_MAIL_ADDRESS:-}" ]]; then
  # Custom SMTP — user set FABRICATE_MAIL_ADDRESS in their .env
  cat >> "${TMP_DIR}/.env" <<EOF

FABRICATE_MAIL_ADDRESS=${FABRICATE_MAIL_ADDRESS}
FABRICATE_MAIL_PORT=${FABRICATE_MAIL_PORT}
FABRICATE_MAIL_USER_NAME=${FABRICATE_MAIL_USER_NAME}
FABRICATE_MAIL_PASSWORD=${FABRICATE_MAIL_PASSWORD}
EOF
  EMAIL_MODE=smtp
elif [[ "${FABRICATE_USE_SES:-false}" == "true" ]]; then
  # SES via EC2 IAM role — no FABRICATE_MAIL_* vars needed
  EMAIL_MODE=ses
else
  # Default: Mailhog local sink (accepts all, never delivers)
  # production.rb requires MAIL_USER_NAME + MAIL_PASSWORD when MAIL_ADDRESS is set;
  # Mailhog ignores credentials entirely.
  cat >> "${TMP_DIR}/.env" <<EOF

FABRICATE_MAIL_ADDRESS=mailhog
FABRICATE_MAIL_PORT=1025
FABRICATE_MAIL_USER_NAME=mailhog
FABRICATE_MAIL_PASSWORD=mailhog
EOF
  EMAIL_MODE=mailhog
fi

if [[ -n "$ANTHROPIC_API_KEY" ]]; then
  cat >> "${TMP_DIR}/.env" <<EOF

FABRICATE_ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
FABRICATE_ANTHROPIC_BASE_URL=https://api.anthropic.com
EOF
fi

# --- docker-compose and nginx config from templates ---
cp "${SCRIPT_DIR}/templates/docker-compose.yaml" "${TMP_DIR}/docker-compose.yaml"
cp "${SCRIPT_DIR}/templates/nginx.conf"           "${TMP_DIR}/nginx.conf"

# Mailhog is a separate compose override file; Docker Compose merges it at runtime.
if [[ "$EMAIL_MODE" == "mailhog" ]]; then
  cp "${SCRIPT_DIR}/templates/docker-compose.mailhog.yaml" "${TMP_DIR}/docker-compose.mailhog.yaml"
fi

# Build the docker compose command used on the instance (base + optional mailhog override)
REMOTE_COMPOSE_CMD="sudo docker compose"
if [[ "$EMAIL_MODE" == "mailhog" ]]; then
  REMOTE_COMPOSE_CMD="sudo docker compose -f docker-compose.yaml -f docker-compose.mailhog.yaml"
fi

# ---------------------------------------------------------------------------
# Upload config to instance
# ---------------------------------------------------------------------------
echo "==> Uploading configuration to instance..."
ssh -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  "ubuntu@${PUBLIC_IP}" "mkdir -p ~/fabricate/certs"

SCP_FILES=("${TMP_DIR}/.env" "${TMP_DIR}/docker-compose.yaml" "${TMP_DIR}/nginx.conf")
[[ "$EMAIL_MODE" == "mailhog" ]] && SCP_FILES+=("${TMP_DIR}/docker-compose.mailhog.yaml")

scp -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  "${SCP_FILES[@]}" \
  "ubuntu@${PUBLIC_IP}:~/fabricate/"

# Generate self-signed TLS certificate on the instance
echo "==> Generating self-signed TLS certificate..."
ssh -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  "ubuntu@${PUBLIC_IP}" \
  "openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout ~/fabricate/certs/fabricate.key \
    -out ~/fabricate/certs/fabricate.crt \
    -subj '/CN=${PUBLIC_IP}' 2>/dev/null"
echo "    Certificate generated (self-signed, valid 365 days)."

# ---------------------------------------------------------------------------
# Start Fabricate
# ---------------------------------------------------------------------------
echo "==> Starting Fabricate services (docker compose up -d)..."
ssh -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  "ubuntu@${PUBLIC_IP}" \
  "cd ~/fabricate && ${REMOTE_COMPOSE_CMD} up -d"
echo "    Services started."

if [[ "$EMAIL_MODE" == "mailhog" ]]; then
  echo "==> Opening port 8025 for Mailhog web UI..."
  aws ec2 authorize-security-group-ingress \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 8025 \
    --cidr "0.0.0.0/0" > /dev/null
fi

# ---------------------------------------------------------------------------
# Wait for the web app to be ready, then pre-install the license
# ---------------------------------------------------------------------------
echo "==> Waiting for Fabricate web app to be ready..."
for i in $(seq 1 60); do
  STATUS=$(ssh -i "$SSH_KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    "ubuntu@${PUBLIC_IP}" \
    "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/" 2>/dev/null || echo "000")
  if [[ "$STATUS" =~ ^[23] ]]; then
    echo "    Web app ready (HTTP $STATUS)."
    break
  fi
  [[ "$i" -eq 60 ]] && { echo "    WARNING: Web app did not respond after 5 minutes; skipping license pre-install." >&2; }
  echo "    Waiting for web app... ($i/60, last status: $STATUS)"
  sleep 5
done

echo "==> Pre-installing license key..."
ssh -i "$SSH_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  "ubuntu@${PUBLIC_IP}" \
  "cd ~/fabricate && ${REMOTE_COMPOSE_CMD} exec -T web bin/rails runner \
    \"AppSetting.set('license_key', ENV.fetch('FABRICATE_LICENSE_KEY'))\"" \
  && echo "    License installed." \
  || echo "    WARNING: License pre-install failed — you will need to enter it in the setup wizard." >&2

# ---------------------------------------------------------------------------
# Auto-create admin user (if AUTO_SETUP_ADMIN=true)
# ---------------------------------------------------------------------------
ADMIN_PASSWORD=""
if [[ "$AUTO_SETUP_ADMIN" == "true" ]]; then
  echo "==> Creating admin user (${ADMIN_EMAIL})..."
  ADMIN_PASSWORD=$(openssl rand -base64 20 | tr -d '/+=' | cut -c1-15)
  ADMIN_RUBY="User.create!(email: '${ADMIN_EMAIL}', password: '${ADMIN_PASSWORD}', password_confirmation: '${ADMIN_PASSWORD}', confirmed_at: Time.now, name: 'Admin')"
  ssh -i "$SSH_KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    "ubuntu@${PUBLIC_IP}" \
    "cd ~/fabricate && ${REMOTE_COMPOSE_CMD} exec -T web bin/rails runner \"${ADMIN_RUBY}\"" \
    && echo "    Admin user created." \
    || echo "    WARNING: Admin user creation failed — create it manually via the setup wizard." >&2
fi

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
echo "  Fabricate:    https://${PUBLIC_IP}  (self-signed cert — click through browser warning)"
echo "  Admin email:  $ADMIN_EMAIL"
if [[ -n "$ADMIN_PASSWORD" ]]; then
echo "  Admin pass:   $ADMIN_PASSWORD"
fi
if [[ "$EMAIL_MODE" == "mailhog" ]]; then
echo "  Mailhog UI:   http://${PUBLIC_IP}:8025  (captured outbound email)"
elif [[ "$EMAIL_MODE" == "smtp" ]]; then
echo "  Email:        SMTP via ${FABRICATE_MAIL_ADDRESS}:${FABRICATE_MAIL_PORT}"
elif [[ "$EMAIL_MODE" == "ses" ]]; then
echo "  Email:        SES (IAM role)"
fi
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
echo "Complete setup at: https://${PUBLIC_IP}"
echo "  (Your browser will warn about a self-signed certificate — click 'Advanced' and proceed.)"
echo "  1. Click 'Get Started'"
echo "  2. Run the compatibility check"
echo "  3. License is pre-installed"
echo "  4. Configure telemetry"
if [[ -n "$ADMIN_PASSWORD" ]]; then
echo "  5. Admin account is pre-created — log in with the credentials above"
else
echo "  5. Create your admin account (use ${ADMIN_EMAIL})"
fi
echo ""

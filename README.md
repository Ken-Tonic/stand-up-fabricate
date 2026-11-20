# stand-up-fabricate

Spins up a self-hosted [Fabricate](https://docs.tonic.ai/fabricate) instance on AWS EC2 using Docker Compose, with nginx providing HTTPS termination via a self-signed certificate.

## Prerequisites

- AWS CLI configured with credentials
- `python3` in your PATH (used for VPC selection)
- `openssl` in your PATH (used to generate random passwords)
- A `.env` file in this directory (see below)

## .env file

Copy the template and fill in your values:

```bash
cp .env.template .env
```

**Required** (provided by Tonic.ai):

| Variable | Description |
|---|---|
| `QUAY_IO_USER` | Quay.io username for pulling Fabricate images |
| `QUAY_IO_PASSWORD` | Quay.io password |
| `FABRICATE_LICENSE` | Fabricate license key (`FAB1.eyJ...`) |
| `ANTHROPIC_API_KEY` | Anthropic API key — required to use Fabricate's AI features |
| `TAGS` | Tags applied to all AWS resources. Format: `Key:Value,Key:Value,...` |

**Optional** (uncomment in `.env` to override):

| Variable | Default | Description |
|---|---|---|
| `INSTANCE_NAME` | `fabricate` | Name tag applied to all resources; also used for the key pair and state file names |
| `INSTANCE_TYPE` | `t3.large` | EC2 instance type (8 GB RAM recommended minimum) |
| `AWS_REGION` | `us-east-1` | AWS region to deploy into |
| `ADMIN_EMAIL` | `admin@fabricate.local` | Email for the initial Fabricate admin account |
| `DISK_SIZE_GB` | `60` | Root EBS volume size in GB |
| `VPC_ID` | _(prompts)_ | Pre-set to skip the interactive VPC selection |
| `AUTO_SETUP_ADMIN` | `false` | When `true`, creates the admin account automatically and prints the generated password at the end — no setup wizard step required |

## Usage

```bash
# Basic — prompts for VPC selection
./stand-up-fabricate.sh

# Override defaults inline (or set them in .env)
INSTANCE_NAME=my-fab \
INSTANCE_TYPE=t3.xlarge \
AWS_REGION=us-west-2 \
  ./stand-up-fabricate.sh

# Tear down all resources
./tear-down-fabricate.sh
# or, if you used a custom instance name:
./tear-down-fabricate.sh my-fab
```

## What it does

1. Presents an interactive VPC selection menu
2. Finds a public subnet (one with an internet gateway route)
3. Creates a security group opening ports 22, 80, and 443 (plus 8025 when using Mailhog)
4. Creates an SSH key pair saved as `<INSTANCE_NAME>-key.pem`
5. Finds the latest Ubuntu 24.04 LTS AMI and launches the EC2 instance
6. Installs Docker via EC2 user-data on first boot
7. Logs in to `quay.io`, pulls the Fabricate images, generates a `SECRET_KEY_BASE`
8. Generates a self-signed TLS certificate on the instance
9. Uploads `docker-compose.yaml`, `nginx.conf`, `.env` (and `docker-compose.mailhog.yaml` when using Mailhog) to `~/fabricate/` on the instance
10. Starts all services with `docker compose up -d`
11. Pre-installs the license key via Rails runner so the setup wizard skips that step
12. _(If `AUTO_SETUP_ADMIN=true`)_ Creates the admin account via Rails runner with a randomly generated password, bypassing Devise email confirmation

All AWS resources are tagged with the key-value pairs defined in `TAGS` in `.env`.

## Completing setup

After the script finishes it prints the URL, e.g. `https://<public-ip>`. Open it in your browser:

- Your browser will warn about the self-signed certificate — click **Advanced → Proceed** to continue.

Then follow the setup wizard:

1. Click **Get Started**
2. Run the compatibility check
3. _(License is pre-installed — this step should be pre-filled)_
4. Configure telemetry
5. Create your admin account (use the `ADMIN_EMAIL` you configured) — _skipped if `AUTO_SETUP_ADMIN=true`; credentials are printed at the end of the script_

### Email delivery

The script supports three modes, configured via `.env`:

| Mode | When | Behaviour |
|---|---|---|
| **Mailhog** (default) | Neither `FABRICATE_MAIL_ADDRESS` nor `FABRICATE_USE_SES` is set | A Mailhog container is added to the Docker stack. All outbound email is captured and viewable at `http://<ip>:8025`. Nothing is ever delivered. |
| **SMTP** | `FABRICATE_MAIL_ADDRESS` is set | Fabricate sends real email via the configured SMTP server. `FABRICATE_MAIL_PORT`, `FABRICATE_MAIL_USER_NAME`, and `FABRICATE_MAIL_PASSWORD` are also required. |
| **SES** | `FABRICATE_USE_SES=true` | Fabricate uses the EC2 instance's IAM role to send via SES. The role must have `ses:SendRawEmail` permission for the sender identity. |

See `.env.template` for the full list of SMTP variables.

### Switching LLM providers after deployment

Other LLM providers (Amazon Bedrock, Azure AI Foundry, OpenAI, Google Vertex AI) can be configured by SSH-ing in and editing `~/fabricate/.env` on the instance, then restarting:

```bash
ssh -i fabricate-key.pem -o IdentitiesOnly=yes ubuntu@<public-ip>
nano ~/fabricate/.env
# If using Mailhog email mode:
sudo docker compose -f docker-compose.yaml -f docker-compose.mailhog.yaml up -d --force-recreate
# Otherwise:
sudo docker compose up -d --force-recreate
```

See the [template.env](https://github.com/TonicAI/fabricate_docker_compose/blob/main/.template.env) for the full list of supported provider variables.

## Repository structure

```
.
├── stand-up-fabricate.sh           # provisions and configures the EC2 instance
├── tear-down-fabricate.sh          # tears down all AWS resources
├── .env                            # your credentials (not committed)
├── .env.template                   # copy this to .env and fill in values
└── templates/
    ├── docker-compose.yaml         # core services: db, redis, pdf-sidecar, web, worker, nginx
    ├── docker-compose.mailhog.yaml # merged in when EMAIL_MODE=mailhog
    └── nginx.conf                  # nginx reverse proxy: HTTP→HTTPS redirect, SSL termination, WebSocket support
```

## Tear down

```bash
./tear-down-fabricate.sh
```

This terminates the EC2 instance, deletes the security group, deletes the key pair, and removes the local `.pem` file. It reads resource IDs from the state file (`.fabricate-state-<INSTANCE_NAME>.env`) written by the stand-up script.

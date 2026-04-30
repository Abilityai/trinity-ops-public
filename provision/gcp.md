# Provision Trinity on Google Cloud

## Prerequisites

```bash
# Install gcloud CLI
brew install --cask google-cloud-sdk   # macOS
# or: https://cloud.google.com/sdk/docs/install

gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

## Recommended Specs

| Resource | Value | Est. cost |
|----------|-------|-----------|
| Machine type | `e2-medium` (2 vCPU, 4 GB) | ~$40/month |
| Boot disk | 50 GB SSD (`pd-ssd`) | ~$8/month |
| Region/Zone | `us-central1-c` | (lowest tier) |
| OS | Ubuntu 24.04 LTS | free |

Need more headroom? Use `e2-standard-2` (2 vCPU, 8 GB, ~$65/month).

## Create the VM

```bash
# Create a cloud-init script that installs Docker
cat > /tmp/trinity-init.sh << 'EOF'
#!/bin/bash
set -e
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 git curl jq
systemctl enable docker && systemctl start docker
usermod -aG docker ubuntu
EOF

# Firewall rule (allow web traffic)
gcloud compute firewall-rules create trinity-web \
  --allow=tcp:80,tcp:443,tcp:8000,tcp:8180 \
  --target-tags=trinity \
  --description="Trinity platform ports"

# Create the VM
gcloud compute instances create trinity-server \
  --zone=us-central1-c \
  --machine-type=e2-medium \
  --image-family=ubuntu-2404-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --metadata-from-file=startup-script=/tmp/trinity-init.sh \
  --tags=trinity \
  --scopes=default
```

## Get the IP

```bash
gcloud compute instances describe trinity-server \
  --zone=us-central1-c \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)'
```

## SSH in

```bash
gcloud compute ssh ubuntu@trinity-server --zone=us-central1-c

# Or with standard SSH after adding your key:
ssh ubuntu@<EXTERNAL_IP>
```

## Add your SSH key (for the ops agent)

```bash
# On your local machine, add your public key
gcloud compute instances add-metadata trinity-server \
  --zone=us-central1-c \
  --metadata="ssh-keys=ubuntu:$(cat ~/.ssh/id_rsa.pub)"
```

## Install Trinity on the VM

SSH into the VM, then:

```bash
git clone https://github.com/abilityai/trinity.git ~/trinity
cd ~/trinity

cp .env.example .env
# Edit .env — set ADMIN_PASSWORD, SECRET_KEY, MCP_API_KEY, ANTHROPIC_API_KEY

docker compose -f docker-compose.prod.yml up -d
```

## Configure the ops agent

In this agent's `.env`:

```bash
SSH_HOST=<EXTERNAL_IP>
SSH_USER=ubuntu
SSH_KEY=~/.ssh/id_rsa
TRINITY_PATH=/home/ubuntu/trinity
BACKEND_PORT=8000
FRONTEND_PORT=80
MCP_PORT=8180
SCHEDULER_PORT=8001
ADMIN_PASSWORD=<your-admin-password>
MCP_API_KEY=<your-mcp-key>
```

## Teardown

```bash
gcloud compute instances delete trinity-server --zone=us-central1-c --quiet
gcloud compute firewall-rules delete trinity-web --quiet
```

## Optional: Disk snapshots (daily backup)

```bash
# Create a snapshot schedule
gcloud compute resource-policies create snapshot-schedule trinity-daily \
  --region=us-central1 \
  --daily-schedule \
  --start-time=03:00 \
  --max-retention-days=7

# Attach to boot disk
gcloud compute disks add-resource-policies trinity-server \
  --zone=us-central1-c \
  --resource-policies=trinity-daily
```

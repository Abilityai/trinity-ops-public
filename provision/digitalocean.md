# Provision Trinity on DigitalOcean

## Prerequisites

```bash
# Install doctl
brew install doctl              # macOS
# or: https://docs.digitalocean.com/reference/doctl/how-to/install/

doctl auth init                 # Paste API token from cloud.digitalocean.com/api/tokens
doctl account get               # Verify auth
```

## Recommended Specs

| Resource | Value | Cost |
|----------|-------|------|
| Size | `s-2vcpu-4gb` (2 vCPU, 4 GB) | $24/month |
| Region | `nyc3` or `fra1` | included |
| OS | Ubuntu 24.04 LTS | free |
| Backups | weekly automated | +$4.80/month |

Need more headroom? Use `s-2vcpu-8gb` ($48/month).

## Upload Your SSH Key

```bash
# List existing keys
doctl compute ssh-key list

# Add a new key
doctl compute ssh-key create trinity-key \
  --public-key "$(cat ~/.ssh/id_rsa.pub)"

# Get the key ID
KEY_ID=$(doctl compute ssh-key list --no-header --format ID,Name | grep trinity-key | awk '{print $1}')
echo "Key ID: $KEY_ID"
```

## Create the Droplet

```bash
# Cloud-init: install Docker
cat > /tmp/trinity-init.sh << 'EOF'
#!/bin/bash
set -e
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 git curl jq
systemctl enable docker && systemctl start docker
usermod -aG docker ubuntu || true
EOF

# Create droplet
doctl compute droplet create trinity-server \
  --region nyc3 \
  --image ubuntu-24-04-x64 \
  --size s-2vcpu-4gb \
  --ssh-keys $KEY_ID \
  --user-data-file /tmp/trinity-init.sh \
  --enable-monitoring \
  --wait \
  --format Name,PublicIPv4,Status
```

## Get the IP

```bash
doctl compute droplet get trinity-server --format PublicIPv4 --no-header
```

## SSH in

```bash
PUBLIC_IP=$(doctl compute droplet get trinity-server --format PublicIPv4 --no-header)
ssh -i ~/.ssh/id_rsa root@$PUBLIC_IP
```

Note: DigitalOcean droplets use `root` by default unless you configure otherwise.

## Install Trinity on the Droplet

SSH in, then:

```bash
# Add a non-root user (recommended)
adduser --disabled-password --gecos "" trinity
usermod -aG docker trinity
usermod -aG sudo trinity

# Install Trinity
su - trinity -c "
  git clone https://github.com/abilityai/trinity.git ~/trinity
  cd ~/trinity
  cp .env.example .env
"
nano /home/trinity/trinity/.env
# Set: ADMIN_PASSWORD, SECRET_KEY, MCP_API_KEY, ANTHROPIC_API_KEY

su - trinity -c "cd ~/trinity && docker compose -f docker-compose.prod.yml up -d"
```

## Configure the ops agent

In this agent's `.env`:

```bash
SSH_HOST=<PUBLIC_IP>
SSH_USER=root                    # or trinity if you created the user
SSH_KEY=~/.ssh/id_rsa
TRINITY_PATH=/root/trinity       # or /home/trinity/trinity
BACKEND_PORT=8000
FRONTEND_PORT=80
MCP_PORT=8180
SCHEDULER_PORT=8001
ADMIN_PASSWORD=<your-admin-password>
MCP_API_KEY=<your-mcp-key>
```

## Add a Firewall (optional but recommended)

```bash
# Create a firewall allowing only necessary ports
doctl compute firewall create \
  --name trinity-fw \
  --inbound-rules "protocol:tcp,ports:22,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:80,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:443,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:8000,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:8180,address:0.0.0.0/0,address:::/0" \
  --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0" \
  --droplet-ids $(doctl compute droplet get trinity-server --format ID --no-header)
```

## Teardown

```bash
doctl compute droplet delete trinity-server --force
```

# Provision Trinity on Hetzner Cloud

Hetzner is the most cost-effective option for Trinity — roughly 5-10x cheaper than AWS/GCP for equivalent specs.

## Prerequisites

```bash
# Install hcloud CLI
brew install hcloud                   # macOS
# or: https://github.com/hetznercloud/cli/releases

# Get API token: Hetzner Console → Your Project → Security → API Tokens
export HCLOUD_TOKEN="your-token-here"

# Create a project context
hcloud context create my-project      # prompted for token
hcloud context use my-project
hcloud server-type list               # verify auth works
```

## Recommended Specs

| Type | vCPU | RAM | Disk | Cost | Use case |
|------|------|-----|------|------|----------|
| `cx23` | 2 | 4 GB | 40 GB SSD | **€3.49/mo** | dev, small production |
| `cx33` | 4 | 8 GB | 80 GB SSD | ~€6-7/mo | production |
| `cpx21` | 2 AMD | 4 GB | 40 GB SSD | ~€4.50/mo | better performance |
| `cpx31` | 4 AMD | 8 GB | 80 GB SSD | ~€8.50/mo | best perf/price |

**Locations:** `nbg1` (Nuremberg), `fsn1` (Falkenstein), `hel1` (Helsinki), `ash` (Ashburn, US)

All plans include 20 TB/month outbound traffic.

## Create the Server

```bash
# 1. Add your SSH key
hcloud ssh-key create \
  --name trinity-key \
  --public-key-from-file ~/.ssh/id_rsa.pub

KEY_ID=$(hcloud ssh-key list -o noheader -o columns=id,name | grep trinity-key | awk '{print $1}')

# 2. Create a firewall
hcloud firewall create --name trinity-fw

hcloud firewall add-rule trinity-fw \
  --direction in --protocol tcp --port 22 \
  --source-ips 0.0.0.0/0 --source-ips ::/0

hcloud firewall add-rule trinity-fw \
  --direction in --protocol tcp --port 80 \
  --source-ips 0.0.0.0/0 --source-ips ::/0

hcloud firewall add-rule trinity-fw \
  --direction in --protocol tcp --port 8000 \
  --source-ips 0.0.0.0/0 --source-ips ::/0

hcloud firewall add-rule trinity-fw \
  --direction in --protocol tcp --port 8180 \
  --source-ips 0.0.0.0/0 --source-ips ::/0

# 3. Write cloud-init (installs Docker)
cat > /tmp/trinity-init.yaml << 'EOF'
#cloud-config
package_update: true
packages:
  - docker.io
  - docker-compose-v2
  - git
  - curl
  - jq
runcmd:
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker ubuntu || true
EOF

# 4. Create the server
hcloud server create \
  --name trinity-server \
  --type cx23 \
  --location nbg1 \
  --image ubuntu-24.04 \
  --ssh-key trinity-key \
  --firewall trinity-fw \
  --user-data-from-file /tmp/trinity-init.yaml
```

## Get the IP

```bash
hcloud server describe trinity-server -o json | jq -r '.public_net.ipv4.ip'

# or
hcloud server list -o columns=name,ipv4
```

## SSH in

```bash
PUBLIC_IP=$(hcloud server describe trinity-server -o json | jq -r '.public_net.ipv4.ip')
ssh root@$PUBLIC_IP
```

Note: Hetzner servers boot as `root`. You can create an `ubuntu` user or work as root.

## Install Trinity on the Server

SSH in, then:

```bash
# Optional: create a non-root user
useradd -m -s /bin/bash -G docker,sudo ubuntu
mkdir -p /home/ubuntu/.ssh
cp ~/.ssh/authorized_keys /home/ubuntu/.ssh/
chown -R ubuntu:ubuntu /home/ubuntu/.ssh

# Install Trinity
git clone https://github.com/abilityai/trinity.git /home/ubuntu/trinity
cd /home/ubuntu/trinity

cp .env.example .env
nano .env
# Set: ADMIN_PASSWORD, SECRET_KEY, MCP_API_KEY, ANTHROPIC_API_KEY

docker compose -f docker-compose.prod.yml up -d
```

## Configure the ops agent

In this agent's `.env`:

```bash
SSH_HOST=<PUBLIC_IP>
SSH_USER=root                     # or ubuntu if you created the user
SSH_KEY=~/.ssh/id_rsa
TRINITY_PATH=/home/ubuntu/trinity # or /root/trinity
BACKEND_PORT=8000
FRONTEND_PORT=80
MCP_PORT=8180
SCHEDULER_PORT=8001
ADMIN_PASSWORD=<your-admin-password>
MCP_API_KEY=<your-mcp-key>
```

## Teardown

```bash
hcloud server delete trinity-server
hcloud firewall delete trinity-fw
hcloud ssh-key delete trinity-key
```

## Optional: Volume for data

For persistent data beyond the boot disk (useful if you resize the server later):

```bash
# Create a 50 GB volume
hcloud volume create --name trinity-data --size 50 --location nbg1

# Attach to server
hcloud volume attach trinity-data --server trinity-server

# On the server: format and mount
mkfs.ext4 /dev/disk/by-id/scsi-0HC_Volume_*
mkdir -p /mnt/trinity-data
echo "/dev/disk/by-id/scsi-0HC_Volume_* /mnt/trinity-data ext4 defaults,nofail 0 0" >> /etc/fstab
mount -a
```

## Optional: Snapshot (manual backup)

```bash
hcloud server create-image trinity-server \
  --type snapshot \
  --description "trinity-$(date +%Y%m%d)"
```

# Provision Trinity on AWS

## Prerequisites

```bash
# Install AWS CLI
brew install awscli                  # macOS
# or: https://aws.amazon.com/cli/

aws configure                        # Enter Access Key ID + Secret
aws sts get-caller-identity          # Verify auth
```

## One-command install (after v0.9.5, #3004)

Upstream's `start.sh --provision --cloud aws` installs Docker, Caddy with an HTTPS certificate for the instance's public IP, a host firewall, and Trinity from prebuilt images on the bundled PostgreSQL. **v0.9.5 and earlier reject `--cloud aws`**, so this needs a later release tag. Upstream's guide on the server: `docs/user-docs/guides/deploying/aws.md`.

Three routes run the same installer:

| Route | Status |
|-------|--------|
| Script install on your own instance | Available (this section) |
| CloudFormation stack, `packer/aws/trinity.cfn.yaml` | Template is in the repo; the public Trinity AMI it launches is not published yet |
| AWS Marketplace AMI | Listing pending |

### Before you run it

| Need | Detail |
|------|--------|
| Instance | x86_64 with **8 GiB** (`t3a.large` is the CloudFormation default; images are `linux/amd64` only), Ubuntu 24.04 |
| Address | A public IPv4: auto-assigned, or an Elastic IP, which also survives a stop/start |
| Security group | TCP **80 and 443** from anywhere (80 carries the Let's Encrypt validation). Keep 22 closed or open it to your own address only. Do **not** open 8000 or 8180: the container ports are not reachable off the instance anyway |
| IAM | No instance role needed |
| Claude | A subscription token (`claude setup-token`) or an Anthropic API key, pasted in the browser afterwards |

To launch one with the CLI, use the commands under [Manual install](#manual-install-source-build) with three changes: `--instance-type t3a.large`, a security group that opens only 80, 443 and (optionally, from your IP) 22, and no cloud-init file.

### Run

On the fresh instance, as root:

```bash
git clone --depth 1 --branch <release-tag> https://github.com/abilityai/trinity.git /opt/trinity
cd /opt/trinity
./scripts/deploy/start.sh --provision --cloud aws --hosted --unattended
```

It reads the public IP from the metadata service (IMDSv2), writes `FRONTEND_PORT=8081`, `FRONTEND_URL=https://<public-ip>` and `TRINITY_INSTALL_SOURCE=aws-script` to `/opt/trinity/.env`, gets the certificate, installs `trinity-ip-refresh.timer`, then runs the hosted install.

### Claim the admin account with the instance ID

With no `ADMIN_PASSWORD` in the environment or `.env`, the installer writes the instance's ID to `trinity-data/setup-claim` (0600) and sets `ADMIN_PASSWORD_SOURCE=instance-id`.

1. Open `https://<public-ip>/`. The certificate is a real one for the IP, so there is no browser warning.
2. The **Create your admin account** form has one extra field, **EC2 instance ID**: the `i-…` value under EC2 → Instances.
3. Admin email is optional (blank = sign in as `admin`). The password needs 12+ characters with upper case, lower case, a digit and a special character.

A wrong ID is refused with "That instance ID does not match this server", rate-limited per IP. The claim file is consumed when the admin is created. Someone who finds the IP first cannot take the instance without reading the ID from your AWS account.

To skip the claim, supply the password up front: `ADMIN_PASSWORD='…' ./scripts/deploy/start.sh --provision --cloud aws --hosted --unattended`. The admin is then `admin` with that password.

Then finish **Connect Claude** (the one required first-run step) and **Secure this instance**.

### When the public IP changes

Without an Elastic IP, EC2 gives the instance a new public IPv4 after a stop/start. `trinity-ip-refresh.timer` checks the metadata service a minute after boot and every five minutes. On a change it re-renders the Caddyfile, gets a certificate for the new address, rewrites `FRONTEND_URL` only if it still pointed at the old IP (a domain you set is kept), and recreates the backend from the images already on the instance. It never pulls or upgrades. Allow a few minutes after a start.

If the instance had **no public IPv4 at first boot**, the installer stops with "this EC2 instance has no public IPv4 address". Attach one; within five minutes the timer finishes the setup, with no shell needed.

The timer runs the checkout's `start.sh` as root every five minutes, so keep `/opt/trinity` owned by root and writable by nobody else.

### Verify

| Check | Command | Expected |
|-------|---------|----------|
| Certificate issued | `cat /etc/trinity/tls-status` | `ok` |
| Recorded address | `cat /etc/trinity/public-ip` | the current public IP |
| Refresh timer | `systemctl status trinity-ip-refresh.timer` | `active (waiting)` |
| Platform | `curl -s http://localhost:8000/health` | `{"status":"healthy",…}` |

### Day two

```bash
cd /opt/trinity
docker compose -f docker-compose.hosted.yml ps     # status
./scripts/deploy/stop.sh                           # stop (never `down`)
./scripts/deploy/start.sh --hosted                 # start, and apply .env changes
```

Upgrade: pin the new release in `.env`, check out the matching tag, re-run `start.sh --hosted` (or `scripts/update.sh` from this repo, which does the last two). Re-rendering Caddy after a `PRIVATE_NETWORK_CIDRS` change must name this cloud: `start.sh --provision --cloud aws --caddy-only`.

Back up `/opt/trinity/.env` (`CREDENTIAL_ENCRYPTION_KEY`, `POSTGRES_PASSWORD`). Nightly database dumps land in `/opt/trinity/trinity-data/backups/`, on the instance's own disk: take EBS snapshots as well.

Ops-agent `.env` for such an instance (the backend port is not reachable from outside; API calls go through `scripts/run.sh` against `localhost`, or `scripts/tunnel.sh`):

```bash
SSH_HOST=<PUBLIC_IP>
SSH_USER=ubuntu            # stock Ubuntu AMIs disable root SSH; this agent's commands use sudo
SSH_KEY=~/.ssh/trinity-aws.pem
TRINITY_PATH=/opt/trinity
COMPOSE_FILE=docker-compose.hosted.yml
FRONTEND_PORT=8081
BACKEND_PORT=8000
```

## Manual install (source build)

The original path: a stock Ubuntu instance and a source build on SQLite. Works on v0.9.5 and needs less memory.

## Recommended Specs

| Resource | Value | Est. cost |
|----------|-------|-----------|
| Instance | `t3.medium` (2 vCPU, 4 GB) | ~$30/month |
| Storage | 50 GB gp3 EBS | ~$4/month |
| Region | `us-east-1` | (lowest pricing) |
| OS | Ubuntu 24.04 LTS | free |

Need more? Use `t3.large` (2 vCPU, 8 GB, ~$60/month).

## Create the Instance

```bash
# 1. Get Ubuntu 24.04 AMI for us-east-1
AMI=$(aws ec2 describe-images \
  --region us-east-1 \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
echo "AMI: $AMI"

# 2. Create security group
SG_ID=$(aws ec2 create-security-group \
  --region us-east-1 \
  --group-name trinity-sg \
  --description "Trinity platform" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --region us-east-1 --group-id $SG_ID \
  --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=tcp,FromPort=8000,ToPort=8000,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=tcp,FromPort=8180,ToPort=8180,IpRanges=[{CidrIp=0.0.0.0/0}]"

# 3. Write cloud-init
cat > /tmp/trinity-init.sh << 'EOF'
#!/bin/bash
set -e
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 git curl jq
systemctl enable docker && systemctl start docker
usermod -aG docker ubuntu
EOF

# 4. Create key pair (skip if you already have one)
aws ec2 create-key-pair \
  --region us-east-1 \
  --key-name trinity-key \
  --query 'KeyMaterial' --output text > ~/.ssh/trinity-aws.pem
chmod 600 ~/.ssh/trinity-aws.pem

# 5. Launch instance
INSTANCE_ID=$(aws ec2 run-instances \
  --region us-east-1 \
  --image-id $AMI \
  --instance-type t3.medium \
  --key-name trinity-key \
  --security-group-ids $SG_ID \
  --user-data file:///tmp/trinity-init.sh \
  --block-device-mappings \
    "DeviceName=/dev/sda1,Ebs={VolumeSize=50,VolumeType=gp3,DeleteOnTermination=true}" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=trinity-server}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "Instance: $INSTANCE_ID"

# 6. Wait for running state
aws ec2 wait instance-running --region us-east-1 --instance-ids $INSTANCE_ID
```

## Get the IP

```bash
aws ec2 describe-instances \
  --region us-east-1 \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

## SSH in

```bash
PUBLIC_IP=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=trinity-server" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

ssh -i ~/.ssh/trinity-aws.pem ubuntu@$PUBLIC_IP
```

## Install Trinity on the Instance

SSH in, then:

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
SSH_HOST=<PUBLIC_IP>
SSH_USER=ubuntu
SSH_KEY=~/.ssh/trinity-aws.pem
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
# Terminate instance
aws ec2 terminate-instances --region us-east-1 --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --region us-east-1 --instance-ids $INSTANCE_ID
aws ec2 delete-security-group --region us-east-1 --group-name trinity-sg
```

## Optional: Elastic IP (static address)

```bash
ALLOC=$(aws ec2 allocate-address --region us-east-1 --query 'AllocationId' --output text)
aws ec2 associate-address --region us-east-1 --instance-id $INSTANCE_ID --allocation-id $ALLOC

# Get static IP
aws ec2 describe-addresses --region us-east-1 \
  --allocation-ids $ALLOC \
  --query 'Addresses[0].PublicIp' --output text
```

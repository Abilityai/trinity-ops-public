# Provision Trinity on AWS

## Prerequisites

```bash
# Install AWS CLI
brew install awscli                  # macOS
# or: https://aws.amazon.com/cli/

aws configure                        # Enter Access Key ID + Secret
aws sts get-caller-identity          # Verify auth
```

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

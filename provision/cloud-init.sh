#!/bin/bash
# Trinity bootstrap script — run as cloud-init user-data or directly on a fresh Ubuntu 22.04/24.04 VM
# Usage as root:  curl -sSL <url> | bash
# Usage via sudo: sudo bash cloud-init.sh

set -e

echo "=== Trinity Bootstrap ==="

# 1. System packages
apt-get update -q
apt-get install -y -q \
    docker.io \
    docker-compose-v2 \
    git \
    curl \
    jq \
    sshpass

# 2. Enable Docker
systemctl enable docker
systemctl start docker

# Allow the default user to run Docker without sudo
# Detect first non-root user with a real home
DEFAULT_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "ubuntu")
if id "$DEFAULT_USER" &>/dev/null; then
    usermod -aG docker "$DEFAULT_USER"
fi

# 3. Install docker-compose v2 standalone (as fallback)
if ! docker compose version &>/dev/null 2>&1; then
    COMPOSE_VERSION="v2.27.0"
    curl -fsSL \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

echo "=== Docker ready ==="
docker --version
docker compose version

echo ""
echo "Next steps:"
echo "  1. Clone Trinity:  git clone https://github.com/abilityai/trinity.git ~/trinity"
echo "  2. Configure:      cp ~/trinity/.env.example ~/trinity/.env && nano ~/trinity/.env"
echo "  3. Start:          cd ~/trinity && docker compose -f docker-compose.prod.yml up -d"

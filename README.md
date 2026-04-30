# Trinity Ops Agent

A [Claude Code](https://claude.ai/code)-powered operations agent for managing a [Trinity Deep Agent Platform](https://github.com/abilityai/trinity) instance — on any server, any cloud, or your laptop.

```
┌───────────────────────────────────────────────────────┐
│              Trinity Ops Agent (this repo)             │
│                                                       │
│  .env  ────────────────────────────────►  Your server │
│  scripts/run.sh                           (SSH or local)│
│                                                       │
│  /status  /update  /restart  /backup  /logs           │
└───────────────────────────────────────────────────────┘
```

## What it does

- **Check health** — container states, HTTP endpoints, Redis, disk
- **Update Trinity** — git pull, rebuild Docker images, restart, verify
- **Manage agents** — list, start, stop, view logs
- **Backup** — SQLite snapshot to `/tmp`
- **Tunnel** — SSH port-forwarding for local browser access to remote instance
- **Provision** — step-by-step guides for Hetzner, GCP, AWS, DigitalOcean, or localhost

## Quick Start

```bash
git clone https://github.com/abilityai/trinity-ops-public.git
cd trinity-ops-public

cp .env.example .env
# Edit .env with your connection details
# Leave SSH_HOST empty if Trinity runs on this machine

# Test it
./scripts/status.sh
```

Then launch Claude Code in this directory:

```bash
claude
```

The agent reads `CLAUDE.md` as its system prompt — it knows how to operate Trinity, check health, read logs, restart services, and walk you through provisioning a new instance.

## Supported Platforms

| Platform | Guide |
|----------|-------|
| **Localhost** (any OS with Docker) | `provision/localhost.md` |
| **Hetzner Cloud** ← cheapest | `provision/hetzner.md` |
| **Google Cloud** | `provision/gcp.md` |
| **AWS** | `provision/aws.md` |
| **DigitalOcean** | `provision/digitalocean.md` |
| Any Linux VM with SSH | Set `.env` and go |

## Minimum Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 2 GB | 4 GB |
| Disk | 20 GB | 50 GB |
| OS | Ubuntu 22.04+ | Ubuntu 24.04 |

## File Structure

```
trinity-ops-public/
├── CLAUDE.md           # Agent instructions (read by Claude Code)
├── .env.example        # Credential template
├── scripts/
│   ├── run.sh          # Execute command locally or via SSH
│   ├── status.sh       # Quick health check
│   ├── restart.sh      # Restart services
│   ├── update.sh       # Pull + rebuild + restart
│   ├── backup.sh       # Database backup
│   └── tunnel.sh       # SSH tunnels for local access
└── provision/
    ├── cloud-init.sh   # Docker bootstrap script
    ├── localhost.md    # Local installation
    ├── hetzner.md      # Hetzner Cloud
    ├── gcp.md          # Google Cloud
    ├── aws.md          # Amazon Web Services
    └── digitalocean.md # DigitalOcean
```

## Usage with Claude Code

Once `.env` is configured, open Claude Code in this directory and ask things like:

- *"What's the status of my Trinity instance?"*
- *"Show me the last 50 backend errors"*
- *"Update Trinity to the latest version"*
- *"Restart the backend and verify it's healthy"*
- *"How do I provision a Hetzner server?"*
- *"My agent container won't start, help me debug"*

## Relation to trinity-ops-agent

`trinity-ops-agent` (Ability AI's internal repo) manages a fleet of 10+ client instances with GCP-specific provisioning, 1Password credential vaults, Tailscale VPN, GitHub Issues backlog, and multi-instance monitoring. This repo is the public, simplified version — one instance, any provider, no external service dependencies.

## License

MIT — see [Trinity](https://github.com/abilityai/trinity) for the platform license.

# Trinity Ops Agent

A [Claude Code](https://claude.ai/code)-powered operations agent for managing a [Trinity](https://github.com/abilityai/trinity) instance — autonomous agent orchestration infrastructure, on any server, any cloud, or your laptop.

```
┌───────────────────────────────────────────────────────┐
│              Trinity Ops Agent (this repo)             │
│                                                       │
│  .env  ────────────────────────────────►  Your server │
│  scripts/run.sh                           (SSH or local)│
│                                                       │
│  /status  /logs  /restart  /update  /diagnose         │
└───────────────────────────────────────────────────────┘
```

## What it does

- **Check health** — container states, HTTP endpoints, Redis, disk
- **Update Trinity** — git pull, rebuild Docker images, restart, verify
- **Manage agents** — list, start, stop, view logs, rebuild containers
- **Diagnose issues** — error scan across all services, resource usage, DB integrity
- **Tunnel** — SSH port-forwarding for local browser access to remote instance
- **Provision** — step-by-step guides for Hetzner, GCP, AWS, DigitalOcean, or localhost

## Getting Started

The recommended path is the `/trinity:deploy` wizard — available in any Claude Code agent that has the [abilities](https://github.com/abilityai/abilities) plugin installed:

```
/trinity:deploy
```

The wizard asks whether you're deploying to the cloud, a remote SSH server, or localhost — then handles Docker install, Trinity setup, `.env` configuration, and clones this repo into `~/{instance-name}-ops` pointed at your instance. When it's done, open the ops agent:

```bash
cd {instance-name}-ops && claude
```

## Manual Setup

If you're wiring up an existing Trinity instance without the wizard:

### Recommended: via `/trinity:deploy`

The easiest way to set this up is through the deploy skill in any Claude Code agent that has the [trinity plugin](https://github.com/abilityai/abilities) installed:

```
/trinity:deploy
```

It walks you through deploying Trinity (or connecting to an existing instance), then clones this repo, and fills in your `.env` automatically.

### Manual setup

```bash
git clone https://github.com/abilityai/trinity-ops-public.git my-instance-ops
cd my-instance-ops

cp .env.example .env
# Edit .env with your connection details
# Leave SSH_HOST empty if Trinity runs on this machine

# Test the connection
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

## Available Skills

| Skill | Description |
|-------|-------------|
| `/status` | Health check — backend, scheduler, containers, version |
| `/logs <service> [lines] [errors]` | View logs for any service or agent |
| `/restart [service\|all]` | Restart services with health verification |
| `/update` | Pull latest, rebuild containers, restart, verify |
| `/agents [list\|start\|stop\|logs\|exec]` | Manage agent containers |
| `/rebuild-agent <name\|--all>` | Rebuild agent container from latest base image |
| `/diagnose` | Full error scan — logs, restarts, disk, DB integrity |
| `/telemetry` | CPU, memory, disk, container resource stats |
| `/rollback [commit] [backup]` | Rollback to previous commit + optional DB restore |
| `/cleanup [--execute]` | Prune Docker images, build cache, old backups |
| `/provision [provider]` | Step-by-step provisioning for any cloud or localhost |

## File Structure

```
trinity-ops-public/
├── CLAUDE.md               # Agent instructions (read by Claude Code)
├── .env.example            # Credential template
├── scripts/
│   ├── run.sh              # Execute command locally or via SSH
│   ├── status.sh           # Quick health check
│   ├── restart.sh          # Restart services
│   ├── update.sh           # Pull + rebuild + restart
│   ├── backup.sh           # Database backup
│   └── tunnel.sh           # SSH tunnels for local access
├── .claude/skills/         # Slash commands
│   ├── status/   logs/   restart/   update/
│   ├── agents/   rebuild-agent/   diagnose/
│   ├── telemetry/   rollback/   cleanup/   provision/
└── provision/
    ├── cloud-init.sh       # Docker bootstrap script
    ├── localhost.md        # Local installation
    ├── hetzner.md          # Hetzner Cloud
    ├── gcp.md              # Google Cloud
    ├── aws.md              # Amazon Web Services
    └── digitalocean.md     # DigitalOcean
```

## Usage with Claude Code

Once `.env` is configured, open Claude Code in this directory and ask things like:

- *"What's the status of my Trinity instance?"*
- *"Show me the last 50 backend errors"*
- *"Update Trinity to the latest version"*
- *"Restart the backend and verify it's healthy"*
- *"How do I provision a Hetzner server?"*
- *"My agent container won't start, help me debug"*

## License

This repo is MIT. Trinity itself is licensed under the [Polyform Noncommercial License 1.0.0](https://github.com/abilityai/trinity/blob/main/LICENSE) — free for personal, research, non-profit, and hobby use; commercial use requires a separate license from [hello@ability.ai](mailto:hello@ability.ai).

---
name: telemetry
description: Show resource usage - host CPU/memory/disk, container stats, Docker disk usage.
disable-model-invocation: true
allowed-tools: Bash, Read
---

# Resource Telemetry

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Host Telemetry via API

```bash
source .env
# Authenticated (SEC-180) — mint the admin token on the host so no tunnel is needed
./scripts/run.sh "TOKEN=\$(curl -s -X POST http://localhost:${BACKEND_PORT:-8000}/token -H 'Content-Type: application/x-www-form-urlencoded' -d 'username=admin&password=$ADMIN_PASSWORD' | jq -r '.access_token // empty'); \
  curl -s -H \"Authorization: Bearer \$TOKEN\" http://localhost:${BACKEND_PORT:-8000}/api/telemetry/host"
```

Returns JSON with CPU, memory, disk stats. (A read-only `ops`-scoped MCP key also reaches this route, #2323 — useful for an external monitor.)

### 3. Container Stats

```bash
source .env
./scripts/run.sh "sudo docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' | grep -E 'NAME|trinity|agent'"
```

### 4. Fallback Host Stats (if API unavailable)

```bash
source .env
./scripts/run.sh "free -h | grep Mem"
./scripts/run.sh "df -h / | tail -1"
```

### 5. Docker Disk Usage

```bash
source .env
./scripts/run.sh "sudo docker system df"
```

### 6. Output Format

```
## Resource Telemetry

### Host Resources
| Metric | Value | Status |
|--------|-------|--------|
| CPU | {%} | ✓/<80%, ⚠️ 80-90%, ✗ >90% |
| Memory | {used}/{total} | {status} |
| Disk (/) | {used}/{total} ({%}) | {status} |

### Containers
| Container | CPU | Memory |
|-----------|-----|--------|
...

### Docker Disk
{docker system df}

### Alerts
{Any metrics above thresholds}
```

---
name: backup
description: Create a timestamped database backup for the Trinity instance.
disable-model-invocation: true
allowed-tools: Bash, Read
---

# Database Backup

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Detect Database Location

```bash
source .env
MOUNT_TYPE=$(./scripts/run.sh "sudo docker inspect trinity-backend --format '{{json .Mounts}}' 2>/dev/null | jq -r '.[] | select(.Destination == \"/data\") | .Type'" 2>/dev/null | tr -d '[:space:]')
echo "Mount type: $MOUNT_TYPE"
```

### 3. Create Backup

```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
BACKUP="trinity-$(date +%Y%m%d-%H%M%S).db"
./scripts/run.sh "mkdir -p ~/backups"
```

**If bind mount:**
```bash
source .env
TRINITY=${TRINITY_PATH:-~/trinity}
./scripts/run.sh "sudo cp $TRINITY/trinity-data/trinity.db ~/backups/$BACKUP"
```

**If Docker volume:**
```bash
./scripts/run.sh "sudo docker run --rm -v trinity_trinity-data:/data -v ~/backups:/backup alpine cp /data/trinity.db /backup/$BACKUP"
```

### 4. Verify Backup

```bash
source .env
./scripts/run.sh "ls -lh ~/backups/$BACKUP"
```

### 5. Report

```
Backup created: ~/backups/{filename}
Size: {size}
Location: {SSH_HOST or localhost}
```

List recent backups:
```bash
source .env
./scripts/run.sh "ls -lt ~/backups/*.db | head -10"
```

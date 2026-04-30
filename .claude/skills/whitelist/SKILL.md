---
name: whitelist
description: Add or remove emails from the Trinity login whitelist.
allowed-tools: Bash, Read
---

# Manage Email Whitelist

Add, remove, or list emails allowed to log into Trinity.

## Instructions

### 1. Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### 2. Parse Input

- Default action: **add**
- "remove", "delete", "revoke" → **remove**
- "list", "show" → **list**
- Accept one or multiple emails

### 3. Load Credentials and Get Token

```bash
source .env
HOST=${SSH_HOST:-localhost}
TOKEN=$(curl -s -X POST http://$HOST:${BACKEND_PORT:-8000}/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=admin&password=$ADMIN_PASSWORD" | jq -r '.access_token')
```

### 4. Execute Action

**Add:**
```bash
source .env
HOST=${SSH_HOST:-localhost}
# default_role: "user" (can log in, use shared agents)
# use "creator" if they need to create agents
curl -s -X POST http://$HOST:${BACKEND_PORT:-8000}/api/settings/email-whitelist \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"email":"EMAIL","source":"manual","default_role":"user"}'
```

A `409` means already whitelisted — not an error.

**Remove:**
```bash
source .env
HOST=${SSH_HOST:-localhost}
curl -s -X DELETE "http://$HOST:${BACKEND_PORT:-8000}/api/settings/email-whitelist/EMAIL" \
  -H "Authorization: Bearer $TOKEN"
```

**List:**
```bash
source .env
HOST=${SSH_HOST:-localhost}
curl -s -H "Authorization: Bearer $TOKEN" \
  http://$HOST:${BACKEND_PORT:-8000}/api/settings/email-whitelist | jq
```

### 5. Report

For each email: added / already existed / removed / not found. Run multiple emails in parallel.

### Notes

- `default_role`: `user` (login + use shared agents), `creator` (can create agents), `operator`, `admin`
- If user needs to create agents, use `"default_role":"creator"`
- Existing users keep their current role; this only applies on first login

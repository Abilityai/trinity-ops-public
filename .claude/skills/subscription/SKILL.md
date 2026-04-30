---
name: subscription
description: Manage Claude Code subscription credentials for Trinity agents. List, register, assign, unassign, validate, and check status.
disable-model-invocation: true
allowed-tools: Bash, Read
argument-hint: <list|register|assign|unassign|validate|status|test> [args]
---

# Subscription Management

Manage Claude Max subscription tokens for Trinity agents. Subscriptions use long-lived tokens (`sk-ant-oat01-*`) from `claude setup-token` — injected as `CLAUDE_CODE_OAUTH_TOKEN` at container creation.

**Auth priority**: `ANTHROPIC_API_KEY` wins over `CLAUDE_CODE_OAUTH_TOKEN`. When a subscription is assigned, Trinity removes the API key; when cleared, the reverse.

## Commands

| Command | Description |
|---------|-------------|
| `/subscription list` | List registered subscriptions |
| `/subscription register <name>` | Register new subscription from setup-token |
| `/subscription assign <agent> <sub>` | Assign subscription to agent |
| `/subscription unassign <agent>` | Remove subscription from agent |
| `/subscription validate <agent>` | Verify agent is using subscription correctly |
| `/subscription status` | Show per-agent auth mode and subscription |
| `/subscription test <sub-name>` | Probe a subscription's live viability |

## Instructions

### Verify Context

```bash
ls -la .env scripts/run.sh 2>/dev/null
```

### Get Token

```bash
source .env
HOST=${SSH_HOST:-localhost}
TOKEN=$(curl -s -X POST http://$HOST:${BACKEND_PORT:-8000}/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=admin&password=$ADMIN_PASSWORD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")
```

---

## Prerequisite: Encryption Key

Subscriptions require `CREDENTIAL_ENCRYPTION_KEY` in Trinity's `~/trinity/.env`.

**Check:**
```bash
source .env
RESULT=$(curl -s -X POST "http://${SSH_HOST:-localhost}:${BACKEND_PORT:-8000}/api/subscriptions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "__test__", "token": "sk-ant-oat01-test", "subscription_type": "test"}')
echo "$RESULT" | grep -q "Encryption key not configured" && echo "KEY MISSING" || echo "KEY OK"
```

**Setup (if missing):**
```bash
source .env
KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
./scripts/run.sh "echo 'CREDENTIAL_ENCRYPTION_KEY=$KEY' >> ${TRINITY_PATH:-~/trinity}/.env"

# Full down+up required (env vars only applied at container creation)
./scripts/run.sh "cd ${TRINITY_PATH:-~/trinity} && sudo docker compose -f ${COMPOSE_FILE:-docker-compose.prod.yml} down && sudo docker compose -f ${COMPOSE_FILE:-docker-compose.prod.yml} up -d"
sleep 15
./scripts/run.sh "curl -s http://localhost:${BACKEND_PORT:-8000}/health"
```

---

## Command: list

```bash
source .env
HOST=${SSH_HOST:-localhost}
curl -s "http://$HOST:${BACKEND_PORT:-8000}/api/subscriptions" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('No subscriptions registered.')
else:
    print('| Name | Type | Agents |')
    print('|------|------|--------|')
    for sub in data:
        agents = ', '.join(sub.get('agents', [])) or '-'
        print(f\"| {sub['name']} | {sub.get('subscription_type','N/A')} | {agents} |\")
"
```

---

## Command: register `<name>`

1. Ask user to run `claude setup-token` on their machine and provide the `sk-ant-oat01-*` token
2. Validate format starts with `sk-ant-oat01-`
3. Register:

```bash
source .env
HOST=${SSH_HOST:-localhost}
curl -s -X POST "http://$HOST:${BACKEND_PORT:-8000}/api/subscriptions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$NAME\", \"token\": \"$TOKEN_VALUE\", \"subscription_type\": \"max\"}"
```

---

## Command: assign `<agent> <subscription>`

```bash
source .env
HOST=${SSH_HOST:-localhost}
curl -s -X PUT "http://$HOST:${BACKEND_PORT:-8000}/api/subscriptions/agents/$AGENT?subscription_name=$SUB_NAME" \
  -H "Authorization: Bearer $TOKEN"
```

Verify after:
```bash
source .env
./scripts/run.sh "sudo docker inspect agent-$AGENT --format='{{range .Config.Env}}{{println .}}{{end}}'" | grep -E 'CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY'
```

Expected: `CLAUDE_CODE_OAUTH_TOKEN` present, `ANTHROPIC_API_KEY` absent.

---

## Command: unassign `<agent>`

```bash
source .env
HOST=${SSH_HOST:-localhost}
curl -s -X DELETE "http://$HOST:${BACKEND_PORT:-8000}/api/subscriptions/agents/$AGENT" \
  -H "Authorization: Bearer $TOKEN"
```

---

## Command: validate `<agent>`

Check three things:

1. **Auth API:**
```bash
source .env
HOST=${SSH_HOST:-localhost}
curl -s "http://$HOST:${BACKEND_PORT:-8000}/api/subscriptions/agents/$AGENT/auth" \
  -H "Authorization: Bearer $TOKEN"
```

2. **Container env:**
```bash
source .env
./scripts/run.sh "sudo docker inspect agent-$AGENT --format='{{range .Config.Env}}{{println .}}{{end}}'" | grep -E 'CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY'
```

3. **Live Claude test:**
```bash
source .env
./scripts/run.sh "sudo docker exec agent-$AGENT bash -c 'claude --print \"respond with OK\" 2>&1 | head -5'"
```

---

## Command: status

```bash
source .env
HOST=${SSH_HOST:-localhost}
AUTH_JSON=$(curl -s "http://$HOST:${BACKEND_PORT:-8000}/api/ops/auth-report" -H "Authorization: Bearer $TOKEN")
echo "$AUTH_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
by_mode = data.get('by_auth_mode', {})
all_agents = (
  [{'name': a.get('name','?'), 'mode': 'subscription', 'sub': a.get('subscription_name','-')} for a in by_mode.get('subscription', [])] +
  [{'name': a.get('name','?'), 'mode': 'api_key', 'sub': '-'} for a in by_mode.get('api_key', [])] +
  [{'name': a.get('name','?'), 'mode': 'none', 'sub': '-'} for a in by_mode.get('none', [])]
)
print('| Agent | Auth Mode | Subscription |')
print('|-------|-----------|--------------|')
unassigned = []
for a in sorted(all_agents, key=lambda x: x['name']):
    print(f\"| {a['name']} | {a['mode']} | {a['sub']} |\")
    if a['mode'] != 'subscription':
        unassigned.append(a['name'])
if unassigned:
    print()
    print(f'WARNING: {len(unassigned)} agent(s) without subscription: {unassigned}')
"
```

---

## Command: test `<sub-name>`

Find an agent bound to the subscription, run a minimal Claude probe inside it:

```bash
source .env
HOST=${SSH_HOST:-localhost}
AGENT=$(curl -s "http://$HOST:${BACKEND_PORT:-8000}/api/ops/auth-report" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json, os
data = json.load(sys.stdin)
subs = data.get('by_auth_mode', {}).get('subscription', [])
match = [a['name'] for a in subs if a.get('subscription_name') == '$SUB_NAME']
print(match[0] if match else '')")

[ -z "$AGENT" ] && { echo "No agents bound to $SUB_NAME"; exit 1; }

echo "Testing '$SUB_NAME' via agent-$AGENT..."
RESP=$(./scripts/run.sh "sudo docker exec agent-$AGENT timeout 30 claude --print 'respond with just OK' 2>&1" || true)
echo "$RESP" | head -10

if echo "$RESP" | grep -qiE '^OK|^ok\b'; then
  echo "RESULT: OK"
elif echo "$RESP" | grep -qi 'usage limit\|429\|rate.?limit'; then
  echo "RESULT: RATE-LIMITED"
elif echo "$RESP" | grep -qi 'invalid.*token\|unauthorized\|401\|403'; then
  echo "RESULT: AUTH ERROR — re-register with a fresh setup-token"
else
  echo "RESULT: UNKNOWN"
fi
```

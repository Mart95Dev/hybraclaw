#!/bin/bash
# HybraClaw Setup Script
# Configures OpenClaw to use Claude Code Max subscription ($0 API)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HYBRACLAW_STATE="${HYBRACLAW_STATE:-$HOME/.hybraclaw}"
GATEWAY_PORT="${GATEWAY_PORT:-18793}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# --- Checks ---

OPENCLAW_DIR="${1:-}"
if [ -z "$OPENCLAW_DIR" ]; then
    echo "Usage: ./setup.sh /path/to/openclaw [--port 18793]"
    echo ""
    echo "Options:"
    echo "  --port PORT    Gateway port (default: 18793)"
    echo "  --state DIR    State directory (default: ~/.hybraclaw)"
    echo ""
    echo "Requirements:"
    echo "  - OpenClaw v2026.3.13+ installed"
    echo "  - Claude Code CLI installed and logged in (claude login)"
    echo "  - Node.js >= 22.12.0"
    exit 1
fi

# Parse optional args
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --port) GATEWAY_PORT="$2"; shift 2 ;;
        --state) HYBRACLAW_STATE="$2"; shift 2 ;;
        *) error "Unknown option: $1" ;;
    esac
done

# Verify OpenClaw
if [ ! -f "$OPENCLAW_DIR/openclaw.mjs" ]; then
    error "OpenClaw not found at $OPENCLAW_DIR. Make sure openclaw.mjs exists."
fi

# Verify Claude CLI
if ! command -v claude &> /dev/null; then
    error "Claude Code CLI not found. Install it: npm install -g @anthropic-ai/claude-code"
fi

# Verify Claude auth
AUTH_STATUS=$(claude auth status 2>&1 | grep -o '"loggedIn": true' || true)
if [ -z "$AUTH_STATUS" ]; then
    error "Claude Code CLI not logged in. Run: claude login"
fi

# Verify credentials file
CREDS="$HOME/.claude/.credentials.json"
if [ ! -f "$CREDS" ]; then
    error "Credentials not found at $CREDS. Run: claude login"
fi

CREDS_SIZE=$(wc -c < "$CREDS")
if [ "$CREDS_SIZE" -lt 400 ]; then
    warn "Credentials file is small ($CREDS_SIZE bytes). It may be incomplete."
    warn "The full file should contain accessToken, refreshToken, expiresAt, scopes, subscriptionType."
    warn "Try running: claude login"
fi

info "OpenClaw: $OPENCLAW_DIR"
info "Claude CLI: $(claude --version 2>&1)"
info "State dir: $HYBRACLAW_STATE"
info "Gateway port: $GATEWAY_PORT"

# --- Create state directory ---

info "Creating state directory..."
mkdir -p "$HYBRACLAW_STATE"/{agents,skills,extensions,memory,cron,logs,workspace,hooks,scripts}

# --- Generate openclaw.json ---

info "Generating openclaw.json..."
cat > "$HYBRACLAW_STATE/openclaw.json" << JSONEOF
{
  "meta": {
    "name": "HybraClaw",
    "version": "1.0.0"
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "claude-cli/sonnet",
        "fallbacks": [
          "claude-cli/haiku"
        ]
      },
      "workspace": "$HYBRACLAW_STATE/workspace",
      "sandbox": {
        "mode": "all",
        "scope": "agent",
        "workspaceAccess": "rw",
        "docker": {
          "readOnlyRoot": true,
          "network": "none",
          "capDrop": ["ALL"],
          "tmpfs": ["/tmp", "/var/tmp", "/run"],
          "pidsLimit": 256,
          "memory": "512m",
          "blockedMounts": [
            "$HYBRACLAW_STATE/.env",
            "$HOME/.claude/.credentials.json",
            "/root/.claude",
            "/etc/shadow",
            "/etc/passwd"
          ]
        }
      },
      "subagents": {
        "maxConcurrent": 3,
        "maxSpawnDepth": 1,
        "maxChildrenPerAgent": 3,
        "runTimeoutSeconds": 600
      },
      "heartbeat": {
        "every": "30m",
        "target": "none"
      }
    },
    "list": []
  },
  "models": {
    "providers": {}
  },
  "channels": {},
  "bindings": [],
  "session": {
    "scope": "per-sender",
    "resetTriggers": ["/new", "/reset"],
    "idleMinutes": 240
  },
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": $GATEWAY_PORT,
    "controlUi": {
      "allowedOrigins": [
        "http://localhost:$GATEWAY_PORT",
        "http://127.0.0.1:$GATEWAY_PORT"
      ]
    }
  },
  "cron": {
    "enabled": true,
    "store": "$HYBRACLAW_STATE/cron/jobs.json",
    "maxConcurrentRuns": 1
  },
  "tools": {
    "web": {
      "search": {
        "enabled": true
      }
    }
  },
  "plugins": {
    "entries": {}
  },
  "hooks": {
    "internal": {
      "enabled": true
    }
  }
}
JSONEOF

# --- Create empty cron jobs ---

if [ ! -f "$HYBRACLAW_STATE/cron/jobs.json" ]; then
    echo '{"version": 1, "jobs": []}' > "$HYBRACLAW_STATE/cron/jobs.json"
fi

# --- Create .env template ---

info "Creating .env template..."
if [ ! -f "$HYBRACLAW_STATE/.env" ]; then
    cat > "$HYBRACLAW_STATE/.env" << ENVEOF
# HybraClaw Environment Variables
# Rename to .env and fill in your values

# Optional: Fallback LLM provider
# OPENROUTER_API_KEY=sk-or-...

# Optional: Web search
# BRAVE_API_KEY=...

# Optional: Telegram bot
# TELEGRAM_BOT_TOKEN=...

# Optional: Perplexity search
# PERPLEXITY_API_KEY=...
ENVEOF
fi

# --- Copy agent templates ---

info "Copying agent templates..."
if [ -d "$SCRIPT_DIR/templates/agents" ]; then
    cp -r "$SCRIPT_DIR/templates/agents/"* "$HYBRACLAW_STATE/agents/" 2>/dev/null || true
fi

# --- Install credential refresh cron ---

info "Setting up credential refresh cron..."
cat > "$SCRIPT_DIR/scripts/refresh-credentials.sh" << 'CRONEOF'
#!/bin/bash
# Refresh Claude Code OAuth credentials
# Checks if the CLI can authenticate and logs status

CREDS="$HOME/.claude/.credentials.json"
LOG="${HYBRACLAW_LOG:-/tmp/hybraclaw-credential-refresh.log}"

if [ ! -f "$CREDS" ]; then
    echo "$(date) ERROR: Credentials not found: $CREDS" >> "$LOG"
    exit 1
fi

# Test authentication
AUTH=$(claude auth status 2>&1 | grep -o '"loggedIn": true' || true)
if [ -z "$AUTH" ]; then
    echo "$(date) WARN: Claude CLI not authenticated, credentials may have expired" >> "$LOG"
    exit 1
fi

echo "$(date) OK: Credentials valid" >> "$LOG"
CRONEOF
chmod +x "$SCRIPT_DIR/scripts/refresh-credentials.sh"

# --- Create systemd service template ---

info "Creating systemd service template..."
cat > "$SCRIPT_DIR/hybraclaw.service" << SVCEOF
[Unit]
Description=HybraClaw Agent Orchestrator
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$OPENCLAW_DIR
Environment=NODE_ENV=production
Environment=OPENCLAW_STATE_DIR=$HYBRACLAW_STATE
Environment=OPENCLAW_GATEWAY_PORT=$GATEWAY_PORT
Environment=OPENCLAW_NO_RESPAWN=1
EnvironmentFile=$HYBRACLAW_STATE/.env
ExecStart=/usr/bin/node openclaw.mjs gateway
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
SVCEOF

# --- Summary ---

echo ""
info "========================================="
info "  HybraClaw setup complete!"
info "========================================="
echo ""
info "State directory: $HYBRACLAW_STATE"
info "Config: $HYBRACLAW_STATE/openclaw.json"
info "Gateway port: $GATEWAY_PORT"
echo ""
info "Next steps:"
echo "  1. Edit $HYBRACLAW_STATE/.env with your API keys"
echo "  2. Add agents to $HYBRACLAW_STATE/openclaw.json"
echo "     (or copy from templates/agents/)"
echo "  3. Install the systemd service:"
echo "     sudo cp hybraclaw.service /etc/systemd/system/"
echo "     sudo systemctl daemon-reload"
echo "     sudo systemctl enable hybraclaw"
echo "     sudo systemctl start hybraclaw"
echo ""
echo "  4. (Optional) Set up credential refresh cron:"
echo "     echo '0 */4 * * * $USER $SCRIPT_DIR/scripts/refresh-credentials.sh' | sudo tee /etc/cron.d/hybraclaw-credentials"
echo ""
info "Control UI: http://localhost:$GATEWAY_PORT"
echo ""

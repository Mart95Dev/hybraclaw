# HybraClaw

> Run OpenClaw multi-agent system with your Claude Code Max subscription — $0 API cost.

HybraClaw is a configuration layer for [OpenClaw](https://github.com/openclaw/openclaw) that enables the built-in `claude-cli` provider to use your Claude Code Max subscription. All 130+ agents run through the official `claude` CLI binary at zero API cost.

## Why HybraClaw

| Setup | Agents | Cost/month | Multi-agent profiles | Memory | Crons |
|-------|--------|-----------|---------------------|--------|-------|
| OpenClaw + OpenRouter | 130 | $400-680 | Yes | Vector search | 60 jobs |
| NanoClaw + Max | 14 groups | $0 | No (groups only) | SQLite basic | Basic |
| **HybraClaw** | **130** | **$0** | **Yes** | **Vector search** | **60 jobs** |

## How it works

OpenClaw already has a `claude-cli` provider in `cli-backends.ts` that spawns the official `claude` binary. HybraClaw configures all agents to use this provider with your Max subscription credentials.

```
Message -> OpenClaw Gateway
  -> Agent routing (per-agent model: opus/sonnet/haiku)
    -> CLI Runner spawns: claude -p --model sonnet --permission-mode bypassPermissions
      -> Claude CLI reads ~/.claude/.credentials.json
        -> Anthropic API ($0, included in Max subscription)
          -> Response
```

No token extraction. No proxy. No credential injection. The official `claude` binary handles everything — fully CGU compliant.

## Requirements

- [OpenClaw](https://github.com/openclaw/openclaw) v2026.3.13 or later
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed globally
- Claude Code Max subscription ($200/month)
- Node.js >= 22.12.0
- pnpm >= 10.x
- Linux VPS (tested on Ubuntu 24.04, Hetzner)

## Quick Start

### 1. Install OpenClaw

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw && pnpm install && pnpm build
```

### 2. Login to Claude Code

```bash
claude login
```

This creates `~/.claude/.credentials.json` with your Max OAuth token.

### 3. Run HybraClaw setup

```bash
git clone https://github.com/Mart95Dev/hybraclaw.git
cd hybraclaw
chmod +x setup.sh
./setup.sh /path/to/openclaw
```

The setup script will:
- Create the HybraClaw state directory (`~/.hybraclaw/`)
- Generate `openclaw.json` with `claude-cli` as the default provider
- Create example agents with SOUL.md templates
- Install the systemd service
- Set up credential refresh cron

### 4. Start

```bash
systemctl start hybraclaw
```

## Manual Configuration

If you prefer manual setup over the script:

### Set the state directory

```bash
export OPENCLAW_STATE_DIR=~/.hybraclaw
```

### Configure `claude-cli` as default provider

In your `openclaw.json`:

```json5
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "claude-cli/sonnet",
        "fallbacks": ["claude-cli/haiku"]
      }
    }
  }
}
```

### Available models

| Model ref | Claude model | Best for |
|-----------|-------------|----------|
| `claude-cli/opus` | Claude Opus 4.6 | Creative writing, strategy, complex reasoning |
| `claude-cli/sonnet` | Claude Sonnet 4.6 | General tasks, SEO, marketing, research |
| `claude-cli/haiku` | Claude Haiku 4.5 | Monitoring, analytics, operational tasks |

### Per-agent model assignment

```json5
{
  "agents": {
    "list": [
      {
        "id": "agent-ceo",
        "model": {
          "primary": "claude-cli/opus",
          "fallbacks": ["claude-cli/sonnet"]
        }
      },
      {
        "id": "agent-monitor",
        "model": {
          "primary": "claude-cli/haiku",
          "fallbacks": []
        }
      }
    ]
  }
}
```

### Add a fallback provider (optional)

Keep OpenRouter as a fallback for when the Max token expires:

```json5
{
  "models": {
    "providers": {
      "openrouter": {
        "baseUrl": "https://openrouter.ai/api/v1",
        "apiKey": "${OPENROUTER_API_KEY}",
        "models": [
          { "id": "anthropic/claude-sonnet-4-6", "name": "Claude Sonnet 4.6" }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "claude-cli/sonnet",
        "fallbacks": ["openrouter/anthropic/claude-sonnet-4-6"]
      }
    }
  }
}
```

## Security

### Recommended sandbox configuration

```json5
{
  "agents": {
    "defaults": {
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
          "memory": "512m"
        }
      }
    }
  }
}
```

OpenClaw's sandbox already **hardcodes blocked paths** (`/etc`, `/proc`, `/sys`, `/dev`, `/root`, `docker.sock`) in `validate-sandbox-security.ts`. Combined with `network: none` and `readOnlyRoot: true`, agents cannot access system files, credentials, or external services.

### Recommended subagent limits

```json5
{
  "agents": {
    "defaults": {
      "subagents": {
        "maxConcurrent": 3,
        "maxSpawnDepth": 1,
        "maxChildrenPerAgent": 3,
        "runTimeoutSeconds": 600
      }
    }
  }
}
```

### CGU compliance

HybraClaw is CGU-compliant because:
1. Uses the **official `claude` binary** — no token extraction
2. `clearEnv: ["ANTHROPIC_API_KEY"]` prevents credential leakage
3. Fallback providers use their own API keys, never the Max token
4. Same mechanism as [NanoClaw](https://github.com/qwibitai/nanoclaw) (24.7k stars, MIT)

## Credential Management

The Max OAuth token expires every ~8 hours. The `claude` CLI handles refresh automatically when called, but a cron ensures freshness:

```bash
# /etc/cron.d/hybraclaw-credentials
0 */4 * * * root /path/to/hybraclaw/scripts/refresh-credentials.sh
```

### Required credential format

The file `~/.claude/.credentials.json` must contain the full OAuth structure:

```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt": 1234567890,
    "scopes": ["user:inference", "user:sessions:claude_code"],
    "subscriptionType": "max",
    "rateLimitTier": "default_claude_max_20x"
  }
}
```

A minimal file with only `accessToken` will NOT work. Run `claude login` to generate the full credentials.

## Quota Planning (Max x5)

| Model | Estimated weekly limit | Typical cron usage | Headroom |
|-------|----------------------|-------------------|----------|
| Opus | ~1,680/week | ~30 calls | 98% |
| Sonnet | ~3,360/week | ~35 calls | 99% |
| Haiku | ~6,720/week | ~80 calls | 99% |

Recommendations:
- Set `serialize: true` in CLI backend config (already default)
- Keep `maxConcurrent: 3` for subagents
- Space out nightly cron pipelines by 30+ minutes
- Use haiku for operational agents, sonnet for creative, opus only for strategy

## Agent Templates

See [`templates/agents/`](templates/agents/) for example agent configurations with SOUL.md, IDENTITY.md, and AGENTS.md files.

## Systemd Service

```ini
[Unit]
Description=HybraClaw Agent Orchestrator
After=network.target

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/openclaw
Environment=OPENCLAW_STATE_DIR=/home/your-user/.hybraclaw
Environment=OPENCLAW_GATEWAY_PORT=18793
Environment=OPENCLAW_NO_RESPAWN=1
EnvironmentFile=/home/your-user/.hybraclaw/.env
ExecStart=/usr/bin/node openclaw.mjs gateway
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
```

## Architecture

```
~/.hybraclaw/                    # State directory (OPENCLAW_STATE_DIR)
  openclaw.json                  # Main config (agents, providers, channels)
  .env                           # Environment variables
  agents/                        # Per-agent directories
    agent-name/
      SOUL.md                    # Personality and tone
      IDENTITY.md                # Name, emoji, role
      AGENTS.md                  # Operational instructions
      workspace/                 # Agent working directory
      sessions/                  # Conversation history
  skills/                        # Custom skills
  extensions/                    # Plugins
  memory/                        # Vector embeddings (SQLite)
  cron/jobs.json                 # Scheduled tasks
```

## FAQ

**Q: Does this violate Anthropic's terms of service?**
No. HybraClaw uses the official `claude` CLI binary to make API calls. It never extracts, proxies, or injects OAuth tokens. This is the same approach as NanoClaw, which has 24.7k stars on GitHub.

**Q: What happens if my Max token expires?**
The CLI handles refresh automatically. If it fails, agents fall back to your configured fallback provider (e.g., OpenRouter). A cron job also syncs credentials every 4 hours.

**Q: Can I use this with the $100/month Max plan?**
Yes, but with lower rate limits (default_claude_max instead of default_claude_max_20x). Reduce `maxConcurrent` and cron frequency accordingly.

**Q: Why not just use NanoClaw?**
NanoClaw uses Docker containers with Claude Agent SDK — simpler but limited to 14 groups without individual agent profiles, per-agent model selection, vector memory, or the full plugin/skill system. HybraClaw gives you the complete OpenClaw feature set at $0.

**Q: Do I need Docker?**
Only if you enable the sandbox (`sandbox.mode: "all"`), which is recommended for security. The core `claude-cli` provider works without Docker.

## License

MIT — Same as OpenClaw.

## Credits

- [OpenClaw](https://github.com/openclaw/openclaw) — The multi-agent gateway
- [NanoClaw](https://github.com/qwibitai/nanoclaw) — Inspiration for Claude Max integration
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — The official CLI

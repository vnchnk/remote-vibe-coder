# Remote Vibe Coder

On-demand dev environment for vibe coding from iOS. Press a button in GitHub Mobile — a VDS spins up on Hetzner with all AI CLI tools and your repo cloned — connect via SSH. Get Telegram notifications with interactive controls.

## Quick Start

1. **Fork this repo**
2. **Create PROD environment** in repo Settings → Environments → New environment → `PROD`
3. **Add secrets** to PROD environment (see details below)
4. **Run workflow** → Actions → "Server" → Run workflow

## Secrets (PROD environment)

All secrets go to: repo Settings → Environments → PROD → Environment secrets.

### Required

| Secret | What it does | How to get |
|--------|-------------|------------|
| `HETZNER_API_TOKEN` | Authenticates with Hetzner Cloud API to create/destroy servers | [Hetzner Console](https://console.hetzner.cloud/) → Select project → Security → API tokens → Generate |
| `SSH_PUBLIC_KEY` | Injected on the server so you can SSH in without password | See [SSH key](#ssh-key) section below |

### Optional

| Secret | What it does | How to get |
|--------|-------------|------------|
| `GH_PAT` | Clones your private repo on the server, enables git push/pull | See [GitHub PAT](#github-pat) section below |
| `TELEGRAM_BOT_TOKEN` | Sends notifications about server lifecycle | See [Telegram Bot](#telegram-bot) section below |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID for notifications | See [Telegram Bot](#telegram-bot) section below |

### SSH key

Generate a key:
```bash
ssh-keygen -t ed25519 -C "sandbox_personal" -f ~/.ssh/sandbox_personal -N ""
```
Copy the public key into `SSH_PUBLIC_KEY` secret:
```bash
cat ~/.ssh/sandbox_personal.pub
```
Import the private key (`~/.ssh/sandbox_personal`) into Blink/Termius on iOS.

### GitHub PAT

Needed to clone private repos on the server. Git push/pull will work automatically.

1. GitHub → **Settings** (your profile, not the repo) → **Developer settings**
2. **Personal access tokens** → **Fine-grained tokens** → **Generate new token**
3. Fill in:
   - **Name:** `remote-vibe-coder`
   - **Expiration:** 90 days (or as needed)
   - **Resource owner:** your username
   - **Repository access:** Only select repositories → select the repo you want to clone
   - **Permissions:** Contents → **Read and write**
4. Copy the token → add as `GH_PAT` secret in PROD environment

### Telegram Bot

Enables notifications when server starts, before auto-delete, and when deleted. Includes interactive buttons to extend or delete the server from Telegram.

**Create a bot:**
1. Open Telegram → find `@BotFather` → send `/newbot`
2. Follow prompts, pick a name and username
3. Copy the **API token** → add as `TELEGRAM_BOT_TOKEN` secret in PROD

**Get your chat ID:**
1. Open your new bot in Telegram and send any message (e.g. `hi`)
2. Open in browser: `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates`
3. Find `"chat": {"id": 123456789}` in the JSON response
4. Copy the number → add as `TELEGRAM_CHAT_ID` secret in PROD

## Usage

```
1. Open GitHub Mobile → Actions → "Server" → Run workflow
2. Select action=start, repository=owner/repo, cloud_server_type=cx23
3. Instantly get Telegram notification with IP (or check workflow output)
4. ssh -i ~/.ssh/sandbox_personal root@<IP>
5. cd playground && claude
6. Done → Run workflow with action=stop (or press "Delete now" in Telegram)
```

If you have a Claude Max subscription, run `claude login` on first connect — it gives a URL, open it on your phone to authenticate.

## Notifications

When `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are configured, you get interactive Telegram notifications:

### Server Started
Sent **instantly** when the server is created (no cloud-init delay). Includes:
- Session ID (e.g. `[a1b2c3d4]`) — same ID in all messages for this server
- IP address and SSH command (tap to copy)
- Time until auto-delete
- All creation parameters (provider, type, location, repo, TTL, etc.)
- **Button:** `Delete now`

### Auto-delete Warning
Sent before auto-delete (configurable via `cloud_warning_minutes`, default 4h before). Includes:
- Session ID
- Actual time remaining until deletion
- **Buttons:** `+1m` | `+10m` | `+1h` | `+1d`

Pressing an extend button:
1. Adds that time to the current deadline
2. Restarts the auto-delete timer
3. Re-sends the warning with updated time remaining and the same extend buttons

You can press extend multiple times — each press adds more time. If TTL is shorter than the warning period (e.g. TTL=5m, warning=4h), the warning is sent immediately at startup.

### Server Deleted
Sent right before the server is destroyed (either by auto-delete or manual delete button). Includes the session ID.

## Workflow Inputs

| Input | Options | Default | Description |
|-------|---------|---------|-------------|
| `action` | `start`, `stop`, `status` | — | What to do |
| `cloud_provider` | `hetzner` | `hetzner` | Cloud provider |
| `cloud_server_type` | `cx23`, `cx33`, `cx43`, `cpx22`, `cax11` | `cx23` | Server size |
| `cloud_location` | `nbg1`, `hel1`, `fsn1` | `nbg1` | Datacenter |
| `repository` | any `owner/repo` | `vnchnk/playground` | Repo to clone |
| `cloud_auto_delete` | `true`, `false` | `true` | Auto-delete after TTL |
| `cloud_ttl_minutes` | any number | `720` (12h) | Server lifetime in minutes |
| `cloud_warning_minutes` | any number | `240` (4h) | Warning before auto-delete |

## What gets installed

- Node.js 22
- `@anthropic-ai/claude-code` (Claude CLI)
- `@openai/codex` (Codex CLI)
- [remote-vibe-panel](https://github.com/vnchnk/remote-vibe-panel) on `:8080` — mobile-first dev panel (git, terminal, docker, db)
- Docker + docker-compose
- git, curl, tmux, htop, jq
- Your repository cloned to `/root/<repo-name>` with git push/pull configured

## Auto-delete

Prevents forgotten servers from burning money. When `cloud_auto_delete=true`:

1. Server starts → self-destruct timer begins (default 12h)
2. At `TTL - warning` minutes → Telegram warning with extend buttons
3. At TTL → server deletes itself via Hetzner API

The timer counts from when cloud-init finishes (not from boot), so setup time doesn't eat into your TTL. You can extend via Telegram buttons or disable auto-delete entirely by setting `cloud_auto_delete=false`.

## Adding a provider

Create `scripts/providers/<name>.sh` with `create`, `destroy`, `status` functions and add the option to the workflow inputs. Each provider script maps generic inputs (`CLOUD_SERVER_TYPE`, `CLOUD_LOCATION`) to provider-specific APIs.

## Architecture

Server name is fixed (`remote-vibe-coder`) — state lives in Hetzner itself, no database or GitHub Variables needed. Each server gets a unique session ID for tracking in notifications.

```
.github/workflows/server.yml   — single workflow: start/stop/status
scripts/providers/hetzner.sh   — create/destroy for Hetzner (hcloud CLI)
scripts/setup.sh               — cloud-init: installs everything on the server
scripts/notify.sh              — Telegram bot: notifications + inline keyboard callbacks
docker-compose.yml             — devpanel (remote-vibe-panel)
```

On the server, three systemd services manage the lifecycle:
- `self-destruct.timer` — fires at TTL, deletes the server
- `self-destruct-warning.timer` — fires before TTL, sends Telegram warning
- `telegram-bot.service` — polls for button callbacks (extend/delete)

#!/usr/bin/env bash
# install.sh — one-command installer for the Telegram agent (macOS, Docker).
#
# This script is self-contained: it does NOT need the source repo. It pulls
# ready-made images from GitHub Container Registry, asks a few questions,
# writes a config file, and starts everything with Docker.
#
# Run it with:
#   bash install.sh
# or, if someone sent you a link:
#   curl -fsSL <the link they gave you> | bash
#
# Re-running this script is safe. If something goes wrong partway through,
# just run it again — it will pick up where it makes sense to and won't
# duplicate anything.

set -euo pipefail

# ─────────────────────────────────────────────────────────── appearance ──

BOLD="$(tput bold 2>/dev/null || true)"
DIM="$(tput dim 2>/dev/null || true)"
RESET="$(tput sgr0 2>/dev/null || true)"
GREEN="$(tput setaf 2 2>/dev/null || true)"
YELLOW="$(tput setaf 3 2>/dev/null || true)"
RED="$(tput setaf 1 2>/dev/null || true)"
CYAN="$(tput setaf 6 2>/dev/null || true)"

say()   { printf '%s\n' "$*"; }
info()  { printf '%s\n' "${CYAN}▸${RESET} $*"; }
ok()    { printf '%s\n' "${GREEN}✅${RESET} $*"; }
warn()  { printf '%s\n' "${YELLOW}⚠️  ${RESET}$*"; }
fail()  { printf '%s\n' "${RED}❌ $*${RESET}" >&2; }
rule()  { printf '%s\n' "${DIM}────────────────────────────────────────────────────────${RESET}"; }

# ──────────────────────────────────────────────────────────── retry hint ──
#
# "$0" only names a real, re-runnable script when this file was saved and
# run directly (docs' Option B, e.g. `bash ~/Downloads/install.sh`). Under
# the RECOMMENDED distribution (`curl -fsSL <gist> | bash`, docs' Option A),
# bash reads the script from stdin and "$0" is just the literal string
# "bash" (or "-bash"/"sh" depending on shell) — so `bash "$0"` would expand
# to `bash "bash"`, which fails with "No such file or directory". Compute
# one distribution-aware hint here and reuse it everywhere we tell the user
# how to retry, instead of ever printing `bash "$0"` directly.
if [[ -n "${0:-}" && "$0" != "bash" && "$0" != "-bash" && "$0" != "sh" && "$0" != "-sh" && -f "$0" && -r "$0" ]]; then
  RETRY_HINT="bash \"$0\""
else
  RETRY_HINT="re-run the install command you were given (the line you pasted into Terminal)"
fi

# Always leave the user with a plain-language way forward, never a bare
# stack trace. Any `exit 1` in this script should be preceded by a fail()
# message explaining what to do next.
trap 'on_error $?' ERR
on_error() {
  local code="$1"
  rule
  fail "Something went wrong (exit code ${code})."
  say "This is safe to retry — nothing is corrupted. Things to try:"
  say "  1. Run this exact same command again:"
  say "       ${BOLD}${RETRY_HINT}${RESET}"
  say "  2. If it keeps failing at the same step, check the logs:"
  say "       ${BOLD}cd \"${WORK_DIR:-~/telegram-agent}\" && docker compose logs${RESET}"
  say "  3. Still stuck? Send the last ~30 lines of the terminal output to"
  say "     whoever gave you this installer — that's usually enough for them"
  say "     to spot the problem."
  exit "$code"
}

WORK_DIR="$HOME/telegram-agent"
COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"

# ─────────────────────────────────────────────────────────── platform ──
# Intel vs Apple-Silicon is resolved by the multi-arch images at pull time —
# no branching for CPU arch. The only real divergence is by OS: how Docker is
# obtained (Docker Desktop app vs Linux Docker Engine) and which URL opener /
# service manager exists.
OS_NAME="$(uname -s)"
case "$OS_NAME" in
  Darwin) PLATFORM="mac";   DEVICE="Mac" ;;
  Linux)  PLATFORM="linux"; DEVICE="Linux machine" ;;
  *)      PLATFORM="other"; DEVICE="computer" ;;
esac

# Best-effort "open this URL in the user's browser", per-OS.
open_url() {
  case "$PLATFORM" in
    mac)   open "$1" >/dev/null 2>&1 || true ;;
    linux) xdg-open "$1" >/dev/null 2>&1 || true ;;
    *)     : ;;
  esac
}

# ─────────────────────────────────────────────────────── interactive input ──
# The RECOMMENDED way to run this is `curl -fsSL <url> | bash`, which makes the
# script ITSELF bash's stdin — so a plain `read` would consume script text / hit
# EOF instead of the keyboard, and every prompt would spin forever. Bind fd 3 to
# the controlling terminal and read every prompt from it (via `read -u 3`),
# leaving stdin for bash to keep reading the script. If there is no terminal
# (genuinely non-interactive, e.g. CI), fall back to stdin.
#
# NOTE: the redirect is tested inside a { …; } group (temporary) rather than as
# `exec 3</dev/tty 2>/dev/null` — an `exec` with no command makes ANY redirect
# on it permanent, so a trailing `2>/dev/null` would silence stderr for the
# whole script and hide every `read -p` prompt (which bash writes to stderr).
if { : </dev/tty; } 2>/dev/null; then
  exec 3</dev/tty # fd 3 → the controlling terminal (keyboard)
else
  exec 3<&0 # no tty available — fall back to the script's stdin
fi

# ───────────────────────────────────────────────────────────────── intro ──

rule
say "${BOLD}Telegram Agent — Installer${RESET}"
rule
say "This will set up a personal Claude-powered assistant that you talk to"
say "through Telegram, running on this ${DEVICE} inside Docker."
say
say "First run typically takes 15–30 minutes, most of which is just Docker"
say "downloading ~4 GB of images in the background. Along the way it asks for:"
say "  • A Telegram bot token (free, from a chat with @BotFather)"
say "  • Your personal Telegram user ID (free, from a chat with @userinfobot)"
say "  • Either a Claude Pro/Max subscription OR an Anthropic API key"
say
say "Nothing is sent anywhere except to Telegram and Anthropic — this all"
say "runs locally on your ${DEVICE}. You can stop or remove it at any time."
say
say "Files will be kept in: ${BOLD}${WORK_DIR}${RESET}"
rule
read -r -u 3 -p "Press Enter to begin (or Ctrl+C to cancel)... " _ || true
say

# ───────────────────────────────────────────────────────────── preflight ──

info "Checking your ${DEVICE}..."
case "$PLATFORM" in
  mac)   ok "Running on macOS." ;;
  linux) ok "Running on Linux." ;;
  *)
    warn "This installer supports macOS and Linux. Your system reports"
    warn "'${OS_NAME}', which isn't tested — continuing, but Docker steps may"
    warn "need manual help. (On Windows, use install.ps1 in PowerShell instead.)"
    ;;
esac

check_docker_installed() {
  command -v docker >/dev/null 2>&1
}

check_docker_running() {
  docker info >/dev/null 2>&1
}

if ! check_docker_installed; then
  if [[ "$PLATFORM" == "mac" ]]; then
    warn "Docker isn't installed yet. Docker is the free tool this agent runs"
    warn "inside of — think of it like a self-contained app container."
    say
    say "Opening the Docker Desktop download page in your browser..."
    open_url "https://www.docker.com/products/docker-desktop/"
    say
    say "${BOLD}What to do:${RESET}"
    say "  1. Download Docker Desktop for Mac (either build is fine — the app"
    say "     picks the right one; Apple Silicon is correct for any Mac from"
    say "     late 2020 onward)."
    say "  2. Open the downloaded file and drag Docker to Applications."
    say "  3. Launch Docker Desktop from Applications. Wait for the whale icon"
    say "     in your menu bar to stop animating (that means it's ready)."
    say
    read -r -u 3 -p "Press Enter once Docker Desktop is installed and open... " _ || true
  else
    warn "Docker isn't installed yet. Docker is the free tool this agent runs"
    warn "inside of. On Linux you install Docker Engine (no Desktop app needed)."
    say
    say "${BOLD}Install it with your distro's package manager, for example:${RESET}"
    say "  • Debian/Ubuntu: ${BOLD}sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin${RESET}"
    say "  • Fedora/RHEL:   ${BOLD}sudo dnf install -y docker docker-compose-plugin${RESET}"
    say "  • Arch:          ${BOLD}sudo pacman -S docker docker-compose${RESET}"
    say "  Official docs (recommended for the latest Docker Engine):"
    say "  ${BOLD}https://docs.docker.com/engine/install/${RESET}"
    say
    say "${BOLD}Then start Docker and allow your user to use it:${RESET}"
    say "  ${BOLD}sudo systemctl enable --now docker${RESET}"
    say "  ${BOLD}sudo usermod -aG docker \"\$USER\"${RESET}   ${DIM}# then log out/in (or run: newgrp docker)${RESET}"
    say
    say "When Docker is installed and running, re-run this installer:"
    say "  ${BOLD}${RETRY_HINT}${RESET}"
    fail "Docker not found — install it, then re-run."
    exit 1
  fi
fi

info "Waiting for Docker to be ready (this can take a minute the first time)..."
ATTEMPTS=0
MAX_ATTEMPTS=60
until check_docker_running; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [[ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]]; then
    say
    fail "Docker still isn't responding after a few minutes."
    say "${BOLD}What to do:${RESET}"
    if [[ "$PLATFORM" == "mac" ]]; then
      say "  1. Open Docker Desktop from your Applications folder (or Spotlight:"
      say "     press Cmd+Space, type 'Docker', press Enter)."
      say "  2. Wait until the whale icon in the menu bar is steady (not moving)."
    else
      say "  1. Start the Docker service: ${BOLD}sudo systemctl start docker${RESET}"
      say "  2. Make sure your user can reach it (you may need to have run"
      say "     ${BOLD}sudo usermod -aG docker \"\$USER\"${RESET} and logged out/in)."
    fi
    say "  3. Run this installer again:"
    say "       ${BOLD}${RETRY_HINT}${RESET}"
    exit 1
  fi
  if [[ "$ATTEMPTS" -eq 1 && "$PLATFORM" == "mac" ]]; then
    open -a Docker >/dev/null 2>&1 || true
  fi
  sleep 3
done
ok "Docker is running."
say

# ─────────────────────────────────────────────────────────── working dir ──

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
info "Working in ${BOLD}${WORK_DIR}${RESET}"
mkdir -p volumes/claude-data volumes/data volumes/whisper-cache volumes/embeddings-cache
say

# ─────────────────────────────────────────────────────────── disk check ──
REQUIRED_GB=15
avail_kb="$(df -Pk "$WORK_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -n "${avail_kb:-}" && "$avail_kb" =~ ^[0-9]+$ ]]; then
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  if (( avail_gb < REQUIRED_GB )); then
    warn "Low disk space: about ${avail_gb} GB free where files go, but the"
    warn "images need roughly ${REQUIRED_GB} GB (they download ~4 GB and unpack"
    warn "to ~14 GB). You can continue, but the download may fail partway."
    read -r -u 3 -p "Continue anyway? [y/N]: " DISK_CONT || true
    if [[ ! "${DISK_CONT:-N}" =~ ^[Yy]$ ]]; then
      fail "Stopped so you can free up disk space first."
      say "Free up some room (empty Trash, remove big files) and re-run:"
      say "  ${BOLD}${RETRY_HINT}${RESET}"
      exit 1
    fi
  else
    ok "Disk space looks fine (~${avail_gb} GB free)."
  fi
fi
say

# ────────────────────────────────────────────────────────── reuse or new ──

RECONFIGURE=1
if [[ -f "$ENV_FILE" ]]; then
  say "It looks like this agent is already set up here (found an existing"
  say "${BOLD}${ENV_FILE}${RESET} in ${WORK_DIR})."
  say
  say "What would you like to do?"
  say "  1) Keep my existing settings and just make sure everything is running"
  say "  2) Start over and reconfigure from scratch (you'll re-enter tokens)"
  read -r -u 3 -p "Choose 1 or 2 [1]: " REUSE_CHOICE || true
  REUSE_CHOICE="${REUSE_CHOICE:-1}"
  if [[ "$REUSE_CHOICE" == "1" ]]; then
    RECONFIGURE=0
    ok "Reusing existing configuration."
  else
    ts="$(date +%Y%m%d%H%M%S)"
    cp "$ENV_FILE" "${ENV_FILE}.bak.${ts}"
    say "Backed up your old settings to ${BOLD}${ENV_FILE}.bak.${ts}${RESET} just in case."
  fi
  say
fi

# ────────────────────────────────────────────────────────────────── util ──

# Reads an existing value for KEY out of .env, if present (used to prefill
# defaults / decide the scope on a "keep settings" re-run).
env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2- || true
}

prompt_nonempty() {
  # prompt_nonempty <prompt text> <varname> [validation regex] [regex hint] [secret]
  #
  # When [secret] is "secret", input is read with `-s` so it never echoes to
  # the terminal (and can't linger in scrollback) — used for the credential
  # prompts (bot token, API key, OAuth token). A newline is printed after,
  # since `-s` swallows the Enter keypress's own newline.
  local prompt="$1" varname="$2" pattern="${3:-}" hint="${4:-}" secret="${5:-}"
  local value=""
  while true; do
    if [[ "$secret" == "secret" ]]; then
      read -r -u 3 -s -p "$prompt" value || true
      say
    else
      read -r -u 3 -p "$prompt" value || true
    fi
    if [[ -z "$value" ]]; then
      warn "That was empty — please paste the value and press Enter."
      continue
    fi
    if [[ -n "$pattern" && ! "$value" =~ $pattern ]]; then
      warn "That doesn't look right. ${hint}"
      continue
    fi
    break
  done
  printf -v "$varname" '%s' "$value"
}

# ─────────────────────────────────────────────────────────── scope menu ──

if [[ "$RECONFIGURE" -eq 1 ]]; then
  say "${BOLD}What would you like to run?${RESET}"
  say "  1) Just the bot ${DIM}(recommended — talk to it in Telegram)${RESET}"
  say "  2) Bot + web admin panel ${DIM}(adds a dashboard at http://localhost:8080)${RESET}"
  say "  3) Everything ${DIM}(adds admin + optional TickTick — needs your own TickTick tokens)${RESET}"
  read -r -u 3 -p "Choose 1, 2, or 3 [1]: " SCOPE_CHOICE || true
  SCOPE_CHOICE="${SCOPE_CHOICE:-1}"
  case "$SCOPE_CHOICE" in
    2) SCOPE_PROFILE="admin" ;;
    3)
      SCOPE_PROFILE="everything"
      say
      warn "TickTick won't actually do anything until you add your own"
      warn "TickTick access token to ${BOLD}${WORK_DIR}/${ENV_FILE}${RESET} afterwards"
      warn "(TICKTICK_ACCESS_TOKEN=...) — it's off by default, not required."
      ;;
    *) SCOPE_PROFILE="" ;;
  esac
  say
else
  SCOPE_PROFILE="$(env_get INSTALL_SCOPE_PROFILE)"
fi

# ───────────────────────────────────────────────────────── credentials ──

if [[ "$RECONFIGURE" -eq 1 ]]; then
  rule
  say "${BOLD}Step 1 of 4 — Telegram bot${RESET}"
  say "Every Telegram bot needs a token from Telegram's official bot creator,"
  say "@BotFather. This is quick:"
  say "  1. Open Telegram and search for ${BOLD}@BotFather${RESET} (blue checkmark)."
  say "  2. Send it the message: ${BOLD}/newbot${RESET}"
  say "  3. Give your bot a display name (anything you like)."
  say "  4. Give it a username — it must end in 'bot', e.g. ${BOLD}mycoolagent_bot${RESET}."
  say "  5. BotFather will reply with a long token like:"
  say "     ${DIM}123456789:ABCdefGHIjklMNOpqrSTUvwxYZ${RESET}"
  say "  6. Copy that whole token and paste it below."
  say
  prompt_nonempty "Paste your bot token: " TELEGRAM_BOT_TOKEN \
    '^[0-9]+:[A-Za-z0-9_-]+$' \
    "It should look like 123456789:ABCdefGHIjkl... (numbers, a colon, then letters/numbers)." \
    "secret"
  ok "Bot token looks good."
  say

  rule
  say "${BOLD}Step 2 of 4 — Your Telegram ID${RESET}"
  say "So the bot only listens to you (and not strangers who find its"
  say "username), it needs your personal numeric Telegram ID:"
  say "  1. In Telegram, search for ${BOLD}@userinfobot${RESET}."
  say "  2. Send it any message, e.g. 'hi'."
  say "  3. It replies with your numeric Id — copy just the number."
  say
  prompt_nonempty "Paste your numeric Telegram ID: " ALLOWED_USER_IDS \
    '^[0-9]+$' \
    "It should be digits only, e.g. 123456789."
  ok "Got it."
  say

  rule
  say "${BOLD}Step 3 of 4 — Claude access${RESET}"
  say "The agent needs a way to talk to Claude (Anthropic's AI). Choose one:"
  say "  1) I have a Claude Pro or Max subscription"
  say "  2) I have (or will create) an Anthropic API key"
  read -r -u 3 -p "Choose 1 or 2 [1]: " CLAUDE_CHOICE || true
  CLAUDE_CHOICE="${CLAUDE_CHOICE:-1}"
  say

  CLAUDE_CODE_OAUTH_TOKEN=""
  ANTHROPIC_API_KEY=""

  if [[ "$CLAUDE_CHOICE" == "2" ]]; then
    say "Get an API key from Anthropic's developer console:"
    say "  1. Open ${BOLD}https://console.anthropic.com${RESET} and sign in (or sign up)."
    say "  2. Make sure billing is set up (Settings → Billing) — API usage is"
    say "     billed per use, separate from any Pro/Max subscription."
    say "  3. Go to Settings → API Keys → Create Key."
    say "  4. Copy the key — it starts with ${DIM}sk-ant-${RESET}."
    say
    prompt_nonempty "Paste your API key: " ANTHROPIC_API_KEY \
      '^sk-ant-' \
      "It should start with sk-ant-." \
      "secret"
    ok "API key looks good."
  else
    say "This uses your Claude Pro/Max subscription instead of a separate"
    say "API bill, via the official Claude CLI's 'setup-token' command."
    say
    if ! command -v claude >/dev/null 2>&1; then
      say "The Claude CLI isn't installed yet. Installing it now..."
      if curl -fsSL https://claude.ai/install.sh | bash; then
        ok "Claude CLI installed."
        hash -r || true
      else
        warn "Automatic install didn't work. No problem — do this manually:"
        say "  1. In a new Terminal window, run:"
        say "       ${BOLD}curl -fsSL https://claude.ai/install.sh | bash${RESET}"
        say "  2. Then run:"
        say "       ${BOLD}claude setup-token${RESET}"
        say "  3. Follow the prompts (it opens a browser to log in), then copy"
        say "     the long token it prints at the end."
        say
        prompt_nonempty "Paste the token from 'claude setup-token': " CLAUDE_CODE_OAUTH_TOKEN \
          "" "" "secret"
      fi
    fi
    if command -v claude >/dev/null 2>&1 && [[ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
      say "Running ${BOLD}claude setup-token${RESET} — this opens your browser to log"
      say "in to your Claude account. Follow the prompts there."
      say
      if claude setup-token; then
        say
        warn "The token was printed above by 'claude setup-token'."
        prompt_nonempty "Paste that token here: " CLAUDE_CODE_OAUTH_TOKEN \
          "" "" "secret"
      else
        warn "That didn't complete. You can run it yourself any time:"
        say "     ${BOLD}claude setup-token${RESET}"
        prompt_nonempty "Paste the resulting token here: " CLAUDE_CODE_OAUTH_TOKEN \
          "" "" "secret"
      fi
    fi
    ok "Claude subscription token captured."
  fi
  say

  rule
  say "${BOLD}Step 4 of 4 — Security keys${RESET}"
  say "Generating two random secret keys used internally between the bot's"
  say "own components (you'll never need to type these anywhere)..."
  BRIDGE_CONTROL_SECRET="$(openssl rand -hex 32)"
  WORKER_CONTROL_SECRET="$(openssl rand -hex 32)"
  ok "Security keys generated."
  say
fi

# ──────────────────────────────────────────────────────────── write .env ──

if [[ "$RECONFIGURE" -eq 1 ]]; then
  info "Writing configuration to ${ENV_FILE}..."
  {
    echo "# Written by install.sh on $(date)"
    echo "# This file holds your secrets. Don't share it or commit it anywhere."
    echo
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
    echo "ALLOWED_USER_IDS=${ALLOWED_USER_IDS}"
    echo
    if [[ -n "$ANTHROPIC_API_KEY" ]]; then
      echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"
    else
      echo "# ANTHROPIC_API_KEY=  (left unset — using a Claude subscription instead)"
    fi
    if [[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
      echo "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}"
    else
      echo "# CLAUDE_CODE_OAUTH_TOKEN=  (left unset — using an API key instead)"
    fi
    echo
    echo "BRIDGE_CONTROL_SECRET=${BRIDGE_CONTROL_SECRET}"
    echo "WORKER_CONTROL_SECRET=${WORKER_CONTROL_SECRET}"
    echo
    echo "# Remembers your menu choice so re-running this script doesn't ask again."
    echo "INSTALL_SCOPE_PROFILE=${SCOPE_PROFILE}"
    echo
    echo "# --- Sane defaults; edit if you know what you're doing ---"
    echo "RATE_LIMIT_HOURLY=30"
    echo "RATE_LIMIT_DAILY=200"
    echo "DB_PATH=data/sessions.db"
    echo "WHISPER_URL=http://whisper:9000"
    echo "WHISPER_MODEL=base.en"
    echo "WHISPER_ENGINE=faster_whisper"
    echo "EMBEDDINGS_URL=http://embeddings:80"
    echo "EMBEDDINGS_MODEL=BAAI/bge-small-en-v1.5"
    echo "LANCE_DB_PATH=/app/data/lance"
    echo "RAG_AUTO_PRUNE=true"
    echo "RAG_PRUNE_DAYS=90"
    echo "ADMIN_PORT=8080"
    echo
    echo "# --- Optional TickTick integration (only used if scope 'Everything' was"
    echo "# chosen) --- it does nothing until you fill these in with your own"
    echo "# TickTick token(s). Leave commented out if you don't use TickTick."
    echo "# TICKTICK_ACCESS_TOKEN="
    echo "# TICKTICK_V2_SESSION_TOKEN="
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Configuration saved to ${WORK_DIR}/${ENV_FILE}."
  say
fi

# ────────────────────────────────────────────────────── write compose ──

info "Writing Docker configuration..."
cat > "$COMPOSE_FILE" <<'COMPOSE_EOF'
# Written by install.sh — pulls pre-built images, no source/build needed.
# See docker-compose.install.yml in the agent repo for the annotated version
# this is generated from, and its "profiles" scheme explained.
services:
  bridge:
    image: ghcr.io/denosyscore/agent-bridge:latest
    container_name: tg-claude-bridge
    restart: unless-stopped
    env_file: .env
    environment:
      WORKER_URL: http://reindexer:7012
      EXECUTOR_URL: http://executor:7014
      WORKER_CONTROL_SECRET: ${WORKER_CONTROL_SECRET}
      # Set unconditionally (not just under "everything") because compose
      # profiles can't scope a single env var — this is harmless when the
      # ticktick-mcp container isn't running: the bot only reaches out to it
      # if the TickTick tool is actually invoked, which requires both the
      # container to be up and TickTick tokens to be set in .env.
      TICKTICK_MCP_URL: http://ticktick-mcp:7013
    depends_on:
      whisper:
        condition: service_started
      embeddings:
        condition: service_started
    volumes:
      - ./volumes/claude-data:/home/bot/.claude
      - ./volumes/data:/app/data
    networks:
      - default
      - execnet
    init: true
    stop_grace_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  reindexer:
    image: ghcr.io/denosyscore/agent-bridge:latest
    container_name: tg-claude-reindexer
    command: ["node", "dist/src/workers/reindex/server.js"]
    restart: unless-stopped
    env_file: .env
    environment:
      WORKER_CONTROL_SECRET: ${WORKER_CONTROL_SECRET}
      LANCE_DB_PATH: /app/data/lance
      EMBEDDINGS_URL: http://embeddings:80
    volumes:
      - ./volumes/data:/app/data
    depends_on:
      embeddings:
        condition: service_started
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  executor:
    image: ghcr.io/denosyscore/agent-executor:latest
    container_name: tg-claude-executor
    restart: unless-stopped
    env_file: .env
    environment:
      WORKER_CONTROL_SECRET: ${WORKER_CONTROL_SECRET}
      EXECUTOR_PORT: "7014"
      EXECUTOR_MAX_CONCURRENCY: ${EXECUTOR_MAX_CONCURRENCY:-3}
    networks:
      - execnet
    mem_limit: 1024m
    pids_limit: 512
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  whisper:
    image: onerahmet/openai-whisper-asr-webservice:v1.9.1
    container_name: tg-claude-whisper
    restart: unless-stopped
    environment:
      ASR_ENGINE: ${WHISPER_ENGINE:-faster_whisper}
      ASR_MODEL: ${WHISPER_MODEL:-base.en}
    volumes:
      - ./volumes/whisper-cache:/root/.cache/whisper
    deploy:
      resources:
        limits:
          memory: 1500M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  embeddings:
    image: ghcr.io/huggingface/text-embeddings-inference:cpu-1.9
    # Upstream has no arm64 build — pin amd64 and let Rosetta emulate it on
    # Apple Silicon. This is the only emulated service; all others are native.
    platform: linux/amd64
    container_name: tg-claude-embeddings
    restart: unless-stopped
    command: --model-id ${EMBEDDINGS_MODEL:-BAAI/bge-small-en-v1.5}
    volumes:
      - ./volumes/embeddings-cache:/data
    deploy:
      resources:
        limits:
          memory: 1500M
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  admin:
    image: ghcr.io/denosyscore/agent-admin:latest
    container_name: tg-claude-admin
    profiles: ["admin", "everything"]
    restart: unless-stopped
    env_file: .env
    environment:
      BRIDGE_CONTROL_URL: http://bridge:7011
    ports:
      - "127.0.0.1:${ADMIN_PORT:-8080}:8080"
    depends_on:
      bridge:
        condition: service_started
    volumes:
      - ./volumes/data:/admin/data:ro
      - ./volumes/claude-data:/admin/claude-data:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  ticktick-mcp:
    image: ghcr.io/denosyscore/agent-ticktick-mcp:latest
    container_name: tg-claude-ticktick-mcp
    profiles: ["everything"]
    restart: unless-stopped
    env_file: .env
    environment:
      TICKTICK_ACCESS_TOKEN: ${TICKTICK_ACCESS_TOKEN:-}
      TICKTICK_V2_SESSION_TOKEN: ${TICKTICK_V2_SESSION_TOKEN:-}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  execnet:
    internal: true
COMPOSE_EOF
ok "Docker configuration written."
say

# ─────────────────────────────────────────────────────── pull + start ──

# NOTE: expand this array everywhere as "${COMPOSE_PROFILE_ARGS[@]+"${COMPOSE_PROFILE_ARGS[@]}"}".
# macOS ships bash 3.2, where a plain "${arr[@]}" on an EMPTY array under
# `set -u` aborts with "unbound variable" — which is exactly the default
# "just the bot" scope (no --profile). The `[@]+…` form expands to nothing when
# the array is empty and is safe on every bash version.
COMPOSE_PROFILE_ARGS=()
if [[ -n "$SCOPE_PROFILE" ]]; then
  COMPOSE_PROFILE_ARGS=(--profile "$SCOPE_PROFILE")
fi

rule
say "${BOLD}Downloading and starting the agent...${RESET}"
say "This step downloads the pre-built images (~4 GB total the first time,"
say "unpacking to ~14 GB on disk). It can take several minutes to half an hour"
say "depending on your internet connection — that's normal, please be patient."
say
if ! docker compose "${COMPOSE_PROFILE_ARGS[@]+"${COMPOSE_PROFILE_ARGS[@]}"}" pull; then
  fail "Downloading the images failed."
  say "${BOLD}What to do:${RESET}"
  say "  • Check your internet connection, then run this installer again:"
  say "      ${BOLD}${RETRY_HINT}${RESET}"
  say "  • If it keeps failing, the images might not be public yet — ask"
  say "    whoever gave you this installer to check."
  exit 1
fi
ok "Images downloaded."
say

info "Starting containers..."
if ! docker compose "${COMPOSE_PROFILE_ARGS[@]+"${COMPOSE_PROFILE_ARGS[@]}"}" up -d; then
  fail "Starting the containers failed."
  say "${BOLD}What to do:${RESET}"
  say "  • Run this installer again:"
  say "      ${BOLD}${RETRY_HINT}${RESET}"
  say "  • To see what went wrong in detail:"
  say "      ${BOLD}cd \"${WORK_DIR}\" && docker compose logs${RESET}"
  exit 1
fi
ok "Containers started."
say

# ────────────────────────────────────────────────────────────── verify ──

info "Waiting for the bot to finish starting up..."
READY=0
for _ in $(seq 1 40); do
  STATUS="$(docker compose ps --status running --services 2>/dev/null | grep -c '^bridge$' || true)"
  if [[ "$STATUS" -ge 1 ]]; then
    if docker compose logs bridge 2>/dev/null | grep -qiE 'allowlist|listening|ready|started'; then
      READY=1
      break
    fi
  fi
  sleep 3
done

say
rule
if [[ "$READY" -eq 1 ]]; then
  ok "${BOLD}Your agent is running!${RESET}"
  say
  say "Open Telegram, find the bot you created with @BotFather, and say hi."
  if [[ "$SCOPE_PROFILE" == "admin" || "$SCOPE_PROFILE" == "everything" ]]; then
    ADMIN_PORT_VAL="$(env_get ADMIN_PORT)"; ADMIN_PORT_VAL="${ADMIN_PORT_VAL:-8080}"
    say "Admin panel: ${BOLD}http://localhost:${ADMIN_PORT_VAL}${RESET}"
  fi
  if [[ "$SCOPE_PROFILE" == "everything" ]]; then
    say "TickTick integration is running but idle until you add your own"
    say "TickTick access token to ${BOLD}${WORK_DIR}/${ENV_FILE}${RESET} — it's optional."
  fi
else
  warn "The bot containers started, but couldn't confirm the bot is fully"
  warn "ready yet. It may just need a bit more time (Whisper/embeddings can"
  warn "take a few extra minutes to warm up on first run)."
  say
  say "Try opening Telegram and messaging your bot now — it may already work."
  say "If it doesn't respond in a few minutes, check what's happening with:"
  say "  ${BOLD}cd \"${WORK_DIR}\" && docker compose logs bridge${RESET}"
fi
rule
say
say "${BOLD}Good to know:${RESET}"
say "  • Stop everything:   ${BOLD}cd \"${WORK_DIR}\" && docker compose stop${RESET}"
say "  • Start it again:    ${BOLD}cd \"${WORK_DIR}\" && docker compose start${RESET}"
say "  • Get updates:       ${BOLD}cd \"${WORK_DIR}\" && docker compose pull && docker compose up -d${RESET}"
say "  • View logs:         ${BOLD}cd \"${WORK_DIR}\" && docker compose logs -f${RESET}"
say "  • Reconfigure:       ${BOLD}${RETRY_HINT}${RESET} ${DIM}(choose 'start over' when asked)${RESET}"
say
say "Everything lives in ${BOLD}${WORK_DIR}${RESET} — your conversations and"
say "settings stay on this Mac."

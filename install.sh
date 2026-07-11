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
  say "       ${BOLD}cd \"${WORK_DIR:-~/telegram-agent}\" && ${CLI_HINT} logs${RESET}"
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

# ─────────────────────────────────────────────────────────── runtime ──
# The stack runs on any OCI runtime with a Docker-compatible compose. We support
# Docker, Colima (a Docker-compatible Lima VM; macOS/Linux), and Podman
# (daemonless; all OSes). Everything below is runtime-agnostic: a single
# compose() wrapper is configured once, and every pull/up/ps/logs call goes
# through it. RUNTIME + CLI_HINT are set during preflight (choose_runtime).
RUNTIME=""
CLI_HINT="docker compose"

have() { command -v "$1" >/dev/null 2>&1; }

# compose() — the ONE way the rest of the script talks to the runtime. For
# Podman + code execution we layer the executor override (see Task 6 / the
# docker-compose.podman.yml written next to the compose file).
compose() {
  case "$RUNTIME" in
    docker|colima) docker compose "$@" ;;
    podman)
      if [[ "${FEAT_EXEC:-0}" == 1 && -f "${WORK_DIR}/docker-compose.podman.yml" ]]; then
        podman compose -f docker-compose.yml -f docker-compose.podman.yml "$@"
      else
        podman compose "$@"
      fi ;;
  esac
}

# runtime_ready — true when the selected runtime's daemon/machine answers.
runtime_ready() {
  case "$RUNTIME" in
    docker|colima) docker info >/dev/null 2>&1 ;;
    podman)        podman info >/dev/null 2>&1 ;;
  esac
}

# ── runtime install/start helpers ────────────────────────────────────────────
wait_runtime_ready() {
  info "Waiting for ${RUNTIME} to be ready (up to a few minutes on first start)..."
  local n=0
  until runtime_ready; do
    n=$((n + 1))
    if [[ "$n" -ge 60 ]]; then
      fail "${RUNTIME} still isn't responding."
      say "Start it manually and re-run: ${BOLD}${RETRY_HINT}${RESET}"
      exit 1
    fi
    sleep 3
  done
}

ensure_docker() {
  if ! have docker; then
    if [[ "$PLATFORM" == "mac" ]]; then
      warn "Docker isn't installed. Opening the Docker Desktop download page..."
      open_url "https://www.docker.com/products/docker-desktop/"
      say "Install Docker Desktop, launch it, then press Enter."
      read -r -u 3 -p "Press Enter once Docker Desktop is installed and running... " _ || true
    else
      warn "Docker isn't installed. Install Docker Engine, e.g.:"
      say "  • Debian/Ubuntu: ${BOLD}sudo apt-get install -y docker.io docker-compose-plugin${RESET}"
      say "  • Fedora/RHEL:   ${BOLD}sudo dnf install -y docker docker-compose-plugin${RESET}"
      say "  • Docs: ${BOLD}https://docs.docker.com/engine/install/${RESET}"
      say "Then ${BOLD}sudo systemctl enable --now docker${RESET} and re-run: ${BOLD}${RETRY_HINT}${RESET}"
      fail "Docker not found."; exit 1
    fi
  fi
  if [[ "$PLATFORM" == "mac" ]] && ! runtime_ready; then open -a Docker >/dev/null 2>&1 || true; fi
  wait_runtime_ready
}

ensure_colima() {
  if ! have colima || ! have docker; then
    if have brew; then
      info "Installing Colima + docker CLI via Homebrew..."
      brew install colima docker docker-compose
    else
      fail "Colima needs Homebrew (https://brew.sh) and the docker CLI."
      say "Install brew, then: ${BOLD}brew install colima docker docker-compose${RESET}, and re-run."
      exit 1
    fi
  fi
  if ! runtime_ready; then
    info "Starting Colima (a small Linux VM; sized for the stack)..."
    colima start --cpu 4 --memory 8 --disk 30
  fi
  wait_runtime_ready
}

ensure_podman() {
  if ! have podman; then
    if [[ "$PLATFORM" == "mac" ]] && have brew; then
      info "Installing Podman via Homebrew..."; brew install podman
    else
      fail "Podman isn't installed."
      say "Install it (${BOLD}https://podman.io/docs/installation${RESET}) and re-run: ${BOLD}${RETRY_HINT}${RESET}"
      exit 1
    fi
  fi
  if ! have podman-compose && ! docker compose version >/dev/null 2>&1; then
    warn "Podman needs a compose provider (podman-compose or the docker compose plugin)."
    say "Install one, e.g. ${BOLD}pip install podman-compose${RESET}, then re-run: ${BOLD}${RETRY_HINT}${RESET}"
  fi
  if [[ "$PLATFORM" == "mac" ]]; then
    podman machine inspect >/dev/null 2>&1 || \
      podman machine init --cpus 4 --memory 8192 --disk-size 30
    runtime_ready || { info "Starting the Podman machine..."; podman machine start; }
  fi
  wait_runtime_ready
}

ensure_runtime() {
  case "$RUNTIME" in
    docker) ensure_docker ;;
    colima) ensure_colima ;;
    podman) ensure_podman ;;
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
say "through Telegram, running on this ${DEVICE} in containers."
say
say "First run typically takes 15–30 minutes, most of which is just the"
say "runtime downloading ~4 GB of images in the background. Along the way it asks for:"
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
    warn "'${OS_NAME}', which isn't tested. (On Windows, use install.ps1.)"
    ;;
esac

# Which container runtimes are already installed?
INSTALLED_RUNTIMES=()
if have docker; then INSTALLED_RUNTIMES+=(docker); fi
if have colima; then INSTALLED_RUNTIMES+=(colima); fi
if have podman; then INSTALLED_RUNTIMES+=(podman); fi

choose_runtime() {
  # One installed → use it. Otherwise (none or several) → ask; ensure_* installs.
  if [[ "${#INSTALLED_RUNTIMES[@]}" -eq 1 ]]; then
    RUNTIME="${INSTALLED_RUNTIMES[0]}"
    ok "Using ${RUNTIME} (the container runtime found on this ${DEVICE})."
    return
  fi
  say "${BOLD}How do you want to run the containers?${RESET}"
  say "  1) Docker ${DIM}(Docker Desktop on Mac; Docker Engine on Linux)${RESET}"
  if [[ "$PLATFORM" != "other" ]]; then
    say "  2) Colima ${DIM}(Docker-compatible, no Docker Desktop; macOS/Linux)${RESET}"
  fi
  say "  3) Podman ${DIM}(daemonless, no Docker Desktop; all OSes)${RESET}"
  read -r -u 3 -p "Choose 1, 2, or 3 [1]: " RT_CHOICE || true
  case "${RT_CHOICE:-1}" in
    2) RUNTIME="colima" ;;
    3) RUNTIME="podman" ;;
    *) RUNTIME="docker" ;;
  esac
  say
}
choose_runtime
case "$RUNTIME" in podman) CLI_HINT="podman compose" ;; *) CLI_HINT="docker compose" ;; esac

ensure_runtime
ok "${RUNTIME} is ready."
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

# read_optional <prompt> <varname> — a single secret read that ALLOWS blank
# (unlike prompt_nonempty, which loops). Used for integration keys the user can
# paste now or add to .env later.
read_optional() {
  local p="$1" v=""
  read -r -u 3 -s -p "$p" v || true
  say
  printf -v "$2" '%s' "$v"
}

# ─────────────────────────────────────────────────────────── scope menu ──

# All feature flags default off; a preset or the customize path turns them on.
FEAT_VOICE=0; FEAT_RAG=0; FEAT_EXEC=0; FEAT_ADMIN=0
FEAT_GITHUB=0; FEAT_NOTION=0; FEAT_BRAVE=0; FEAT_WEATHER=0; FEAT_NEWS=0
FEAT_GMAIL=0; FEAT_SPOTIFY=0; FEAT_TICKTICK=0; FEAT_BASH=0
GITHUB_TOKEN_VAL=""; NOTION_TOKEN_VAL=""; BRAVE_KEY_VAL=""

apply_preset() {
  case "$1" in
    recommended) FEAT_VOICE=1; FEAT_RAG=1; FEAT_EXEC=1 ;;
    everything)  FEAT_VOICE=1; FEAT_RAG=1; FEAT_EXEC=1; FEAT_ADMIN=1
                 FEAT_WEATHER=1; FEAT_NEWS=1
                 FEAT_GITHUB=1; FEAT_NOTION=1; FEAT_BRAVE=1
                 FEAT_GMAIL=1; FEAT_SPOTIFY=1; FEAT_TICKTICK=1 ;;
    minimal)     : ;;  # chat only — everything stays off
  esac
}

yn() { # yn "Question" default(0|1) -> echoes 0 or 1
  local q="$1" def="$2" ans hint="[y/N]"
  [[ "$def" == 1 ]] && hint="[Y/n]"
  read -r -u 3 -p "  ${q} ${hint}: " ans || true
  if [[ -z "${ans:-}" ]]; then echo "$def"
  elif [[ "$ans" =~ ^[Yy]$ ]]; then echo 1
  else echo 0; fi
}

if [[ "$RECONFIGURE" -eq 1 ]]; then
  say "${BOLD}What would you like to install?${RESET}"
  say "  1) Recommended ${DIM}(chat + voice + memory/RAG + code execution)${RESET}"
  say "  2) Everything  ${DIM}(adds admin panel + all integrations)${RESET}"
  say "  3) Minimal     ${DIM}(chat only)${RESET}"
  say "  4) Customize   ${DIM}(choose each capability + integration)${RESET}"
  read -r -u 3 -p "Choose 1-4 [1]: " PRESET_CHOICE || true
  case "${PRESET_CHOICE:-1}" in
    2) apply_preset everything ;;
    3) apply_preset minimal ;;
    4) apply_preset recommended  # customize starts from Recommended, then overrides
       say; say "${BOLD}Capabilities${RESET} (press Enter to keep the shown default):"
       FEAT_VOICE=$(yn "Voice messages (Whisper transcription)?" "$FEAT_VOICE")
       FEAT_RAG=$(yn   "Semantic memory / search of past chats (RAG)?" "$FEAT_RAG")
       FEAT_EXEC=$(yn  "Code execution (sandboxed)?" "$FEAT_EXEC")
       FEAT_ADMIN=$(yn "Web admin dashboard?" "$FEAT_ADMIN")
       say; say "${BOLD}Integrations${RESET}:"
       FEAT_GITHUB=$(yn  "GitHub (needs a token)?" "$FEAT_GITHUB")
       FEAT_NOTION=$(yn  "Notion (needs a token)?" "$FEAT_NOTION")
       FEAT_BRAVE=$(yn   "Brave Search (needs a key)?" "$FEAT_BRAVE")
       FEAT_WEATHER=$(yn "Weather (free)?" "$FEAT_WEATHER")
       FEAT_NEWS=$(yn    "News / GDELT (free)?" "$FEAT_NEWS")
       FEAT_GMAIL=$(yn   "Gmail (OAuth — set up after install)?" "$FEAT_GMAIL")
       FEAT_SPOTIFY=$(yn "Spotify (OAuth — set up after install)?" "$FEAT_SPOTIFY")
       FEAT_TICKTICK=$(yn "TickTick (OAuth — set up after install)?" "$FEAT_TICKTICK")
       say; say "${BOLD}Advanced${RESET}:"
       warn "The Bash tool lets Claude run shell commands in the container. If the"
       warn "bot is ever prompt-injected, that can read env vars or exfiltrate data."
       FEAT_BASH=$(yn "Enable the Bash tool (leave off unless you need it)?" "$FEAT_BASH")
       ;;
    *) apply_preset recommended ;;
  esac
  say

  # Simple-key integrations: paste the secret now, or leave blank to add later.
  [[ "$FEAT_GITHUB" == 1 ]] && read_optional "Paste a GitHub token (blank = add to .env later): " GITHUB_TOKEN_VAL
  [[ "$FEAT_NOTION" == 1 ]] && read_optional "Paste a Notion token (blank = add later): " NOTION_TOKEN_VAL
  [[ "$FEAT_BRAVE"  == 1 ]] && read_optional "Paste a Brave Search key (blank = add later): " BRAVE_KEY_VAL
else
  # Re-run "keep settings": restore the saved feature selection so compose is
  # regenerated to match (the installer wrote .install-manifest last time).
  [[ -f .install-manifest ]] && source ./.install-manifest || true
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
    echo "# Written by install.sh on $(date). Holds secrets — don't share/commit."
    echo
    echo "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}"
    echo "ALLOWED_USER_IDS=${ALLOWED_USER_IDS}"
    echo
    [[ -n "$ANTHROPIC_API_KEY" ]] && echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" || echo "# ANTHROPIC_API_KEY=  (using a Claude subscription)"
    [[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]] && echo "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}" || echo "# CLAUDE_CODE_OAUTH_TOKEN=  (using an API key)"
    echo
    echo "BRIDGE_CONTROL_SECRET=${BRIDGE_CONTROL_SECRET}"
    echo "WORKER_CONTROL_SECRET=${WORKER_CONTROL_SECRET}"
    echo
    echo "# --- Defaults ---"
    echo "RATE_LIMIT_HOURLY=30"
    echo "RATE_LIMIT_DAILY=200"
    echo "DB_PATH=data/sessions.db"
    # Voice off ⇒ empty WHISPER_URL disables voice gracefully in the bridge.
    [[ "$FEAT_VOICE" == 1 ]] && echo "WHISPER_URL=http://whisper:9000" || echo 'WHISPER_URL='
    echo "WHISPER_MODEL=base.en"
    echo "WHISPER_ENGINE=faster_whisper"
    # RAG off ⇒ empty EMBEDDINGS_URL disables semantic history gracefully.
    [[ "$FEAT_RAG" == 1 ]] && echo "EMBEDDINGS_URL=http://embeddings:80" || echo 'EMBEDDINGS_URL='
    echo "EMBEDDINGS_MODEL=BAAI/bge-small-en-v1.5"
    echo "LANCE_DB_PATH=/app/data/lance"
    echo "RAG_AUTO_PRUNE=true"
    echo "RAG_PRUNE_DAYS=90"
    echo "ADMIN_PORT=8080"
    [[ "$FEAT_BASH" == 1 ]] && echo "ENABLE_BASH=true"
    echo
    echo "# --- Integrations ---"
    [[ "$FEAT_WEATHER" == 1 ]] && echo "ENABLE_WEATHER_MCP=true"
    [[ "$FEAT_NEWS"    == 1 ]] && echo "ENABLE_NEWS_MCP=true"
    if [[ "$FEAT_GITHUB" == 1 ]]; then [[ -n "$GITHUB_TOKEN_VAL" ]] && echo "GITHUB_TOKEN=${GITHUB_TOKEN_VAL}" || echo "# GITHUB_TOKEN=  (enabled — paste your token here to activate)"; fi
    if [[ "$FEAT_NOTION" == 1 ]]; then [[ -n "$NOTION_TOKEN_VAL" ]] && echo "NOTION_TOKEN=${NOTION_TOKEN_VAL}" || echo "# NOTION_TOKEN=  (enabled — paste your token here)"; fi
    if [[ "$FEAT_BRAVE" == 1 ]]; then [[ -n "$BRAVE_KEY_VAL" ]] && echo "BRAVE_API_KEY=${BRAVE_KEY_VAL}" || echo "# BRAVE_API_KEY=  (enabled — paste your key here)"; fi
    if [[ "$FEAT_GMAIL" == 1 ]]; then echo "GMAIL_OAUTH_PATH=/app/data/gmail/gcp-oauth.keys.json"; echo "GMAIL_CREDENTIALS_PATH=/app/data/gmail/credentials.json"; fi
    if [[ "$FEAT_SPOTIFY" == 1 ]]; then echo "# SPOTIFY_CLIENT_ID="; echo "# SPOTIFY_CLIENT_SECRET="; echo "# SPOTIFY_REFRESH_TOKEN="; fi
    if [[ "$FEAT_TICKTICK" == 1 ]]; then echo "# TICKTICK_ACCESS_TOKEN="; echo "# TICKTICK_V2_SESSION_TOKEN="; fi
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  # Feature manifest — kept OUT of .env (which is passed to every container) so a
  # "keep settings" re-run regenerates the same compose.
  {
    echo "# Written by install.sh — your feature selection. A 'start over' re-run recreates it."
    for f in FEAT_VOICE FEAT_RAG FEAT_EXEC FEAT_ADMIN FEAT_GITHUB FEAT_NOTION FEAT_BRAVE FEAT_WEATHER FEAT_NEWS FEAT_GMAIL FEAT_SPOTIFY FEAT_TICKTICK FEAT_BASH; do
      echo "${f}=${!f}"
    done
  } > .install-manifest
  ok "Configuration saved to ${WORK_DIR}/${ENV_FILE}."
  say
fi

# ────────────────────────────────────────────────────── write compose ──

info "Writing container configuration for ${RUNTIME}..."

# The bridge's env/depends_on/networks reference only the services that exist.
bridge_env() {
  echo "      WORKER_CONTROL_SECRET: \${WORKER_CONTROL_SECRET}"
  [[ "$FEAT_RAG"      == 1 ]] && echo "      WORKER_URL: http://reindexer:7012"
  [[ "$FEAT_EXEC"     == 1 ]] && echo "      EXECUTOR_URL: http://executor:7014"
  [[ "$FEAT_TICKTICK" == 1 ]] && echo "      TICKTICK_MCP_URL: http://ticktick-mcp:7013"
  return 0
}
bridge_depends() {
  [[ "$FEAT_VOICE" == 1 || "$FEAT_RAG" == 1 ]] || return 0
  echo "    depends_on:"
  [[ "$FEAT_VOICE" == 1 ]] && printf '      whisper:\n        condition: service_started\n'
  [[ "$FEAT_RAG"   == 1 ]] && printf '      embeddings:\n        condition: service_started\n'
  return 0
}
bridge_networks() {
  echo "    networks:"
  echo "      - default"
  [[ "$FEAT_EXEC" == 1 ]] && echo "      - execnet"
  return 0
}

{
  echo "# Written by install.sh for ${RUNTIME}. Generated from your feature"
  echo "# selection — services you turned off are omitted. See"
  echo "# deploy/docker-compose.install.yml for the full annotated reference."
  echo "services:"
  echo "  bridge:"
  echo "    image: ghcr.io/denosyscore/agent-bridge:latest"
  echo "    container_name: tg-claude-bridge"
  echo "    restart: unless-stopped"
  echo "    env_file: .env"
  echo "    environment:"
  bridge_env
  bridge_depends
  echo "    volumes:"
  echo "      - ./volumes/claude-data:/home/bot/.claude"
  echo "      - ./volumes/data:/app/data"
  bridge_networks
  echo "    init: true"
  echo "    stop_grace_period: 30s"
  echo '    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }'

  if [[ "$FEAT_RAG" == 1 ]]; then
    cat <<'YAML'

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
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }

  embeddings:
    image: ghcr.io/huggingface/text-embeddings-inference:cpu-1.9
    # Upstream has no arm64 build — pin amd64; Rosetta/binfmt emulates it.
    platform: linux/amd64
    container_name: tg-claude-embeddings
    restart: unless-stopped
    command: --model-id ${EMBEDDINGS_MODEL:-BAAI/bge-small-en-v1.5}
    volumes:
      - ./volumes/embeddings-cache:/data
    deploy: { resources: { limits: { memory: 1500M } } }
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
YAML
  fi

  if [[ "$FEAT_EXEC" == 1 ]]; then
    cat <<'YAML'

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
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
YAML
  fi

  if [[ "$FEAT_VOICE" == 1 ]]; then
    cat <<'YAML'

  whisper:
    image: onerahmet/openai-whisper-asr-webservice:v1.9.1
    container_name: tg-claude-whisper
    restart: unless-stopped
    environment:
      ASR_ENGINE: ${WHISPER_ENGINE:-faster_whisper}
      ASR_MODEL: ${WHISPER_MODEL:-base.en}
    volumes:
      - ./volumes/whisper-cache:/root/.cache/whisper
    deploy: { resources: { limits: { memory: 1500M } } }
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
YAML
  fi

  if [[ "$FEAT_ADMIN" == 1 ]]; then
    cat <<'YAML'

  admin:
    image: ghcr.io/denosyscore/agent-admin:latest
    container_name: tg-claude-admin
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
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
YAML
  fi

  if [[ "$FEAT_TICKTICK" == 1 ]]; then
    cat <<'YAML'

  ticktick-mcp:
    image: ghcr.io/denosyscore/agent-ticktick-mcp:latest
    container_name: tg-claude-ticktick-mcp
    restart: unless-stopped
    env_file: .env
    environment:
      TICKTICK_ACCESS_TOKEN: ${TICKTICK_ACCESS_TOKEN:-}
      TICKTICK_V2_SESSION_TOKEN: ${TICKTICK_V2_SESSION_TOKEN:-}
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
YAML
  fi

  if [[ "$FEAT_EXEC" == 1 ]]; then
    printf '\nnetworks:\n  execnet:\n    internal: true\n'
  fi
} > "$COMPOSE_FILE"

# Podman + code execution: layer an override giving the executor's bubblewrap
# sandbox the nested-namespace room it needs under (rootless) Podman. compose()
# applies it with -f; the post-up self-test is the real guarantee.
if [[ "$RUNTIME" == "podman" && "$FEAT_EXEC" == 1 ]]; then
  cat > docker-compose.podman.yml <<'YAML'
services:
  executor:
    security_opt:
      - label=disable
    annotations:
      run.oci.keep_original_groups: "1"
    userns_mode: keep-id
YAML
fi
ok "Container configuration written ($(grep -cE '^  [a-z][a-z-]*:$' "$COMPOSE_FILE") services)."
say

# ─────────────────────────────────────────────────────── pull + start ──

rule
say "${BOLD}Downloading and starting the agent...${RESET}"
say "This step downloads the pre-built images (~4 GB total the first time,"
say "unpacking to ~14 GB on disk). It can take several minutes to half an hour"
say "depending on your internet connection — that's normal, please be patient."
say
if ! compose pull; then
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
if ! compose up -d; then
  fail "Starting the containers failed."
  say "${BOLD}What to do:${RESET}"
  say "  • Run this installer again:"
  say "      ${BOLD}${RETRY_HINT}${RESET}"
  say "  • To see what went wrong in detail:"
  say "      ${BOLD}cd \"${WORK_DIR}\" && ${CLI_HINT} logs${RESET}"
  exit 1
fi
ok "Containers started."
say

# ── executor sandbox health (fail loud, never degrade silently) ──
if [[ "$FEAT_EXEC" == 1 ]]; then
  info "Verifying the code-execution sandbox..."
  exec_ok=0
  for _ in $(seq 1 20); do
    st="$(compose ps --status running --services 2>/dev/null | grep -c '^executor$' || true)"
    if [[ "$st" -ge 1 ]] && ! compose logs executor 2>/dev/null | grep -qiE 'sandbox.*(fail|not operational|disabled)'; then
      exec_ok=1; break
    fi
    # A fail-closed executor crash-loops out of 'running'; stop once it has spoken.
    if compose logs executor 2>/dev/null | grep -qiE 'self-test|sandbox'; then break; fi
    sleep 3
  done
  if [[ "$exec_ok" -ne 1 ]]; then
    warn "The code-execution sandbox did not come up cleanly."
    if [[ "$RUNTIME" == "podman" ]]; then
      say "Rootless Podman can block the nested namespaces bubblewrap needs. Options:"
      say "  • Rootful Podman machine: ${BOLD}podman machine set --rootful && podman machine stop && podman machine start${RESET}"
      say "  • Or re-run and choose Docker or Colima."
    fi
    say "Full executor log: ${BOLD}cd \"${WORK_DIR}\" && ${CLI_HINT} logs executor${RESET}"
    fail "Refusing to enable code execution unsandboxed. Fix the sandbox (above) and re-run, or turn off code execution when the menu asks."
    exit 1
  fi
  ok "Code-execution sandbox is healthy."
  say
fi

# ────────────────────────────────────────────────────────────── verify ──

info "Waiting for the bot to finish starting up..."
READY=0
for _ in $(seq 1 40); do
  STATUS="$(compose ps --status running --services 2>/dev/null | grep -c '^bridge$' || true)"
  if [[ "$STATUS" -ge 1 ]]; then
    if compose logs bridge 2>/dev/null | grep -qiE 'allowlist|listening|ready|started'; then
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
  if [[ "$FEAT_ADMIN" == 1 ]]; then
    ADMIN_PORT_VAL="$(env_get ADMIN_PORT)"; ADMIN_PORT_VAL="${ADMIN_PORT_VAL:-8080}"
    say "Admin panel: ${BOLD}http://localhost:${ADMIN_PORT_VAL}${RESET}"
  fi
  if [[ "$FEAT_TICKTICK" == 1 ]]; then
    say "TickTick is running but idle until you finish its OAuth setup and add the"
    say "token to ${BOLD}${WORK_DIR}/${ENV_FILE}${RESET} — it's optional."
  fi
else
  warn "The bot containers started, but couldn't confirm the bot is fully"
  warn "ready yet. It may just need a bit more time (Whisper/embeddings can"
  warn "take a few extra minutes to warm up on first run)."
  say
  say "Try opening Telegram and messaging your bot now — it may already work."
  say "If it doesn't respond in a few minutes, check what's happening with:"
  say "  ${BOLD}cd \"${WORK_DIR}\" && ${CLI_HINT} logs bridge${RESET}"
fi
rule
say
say "${BOLD}Good to know:${RESET}"
say "  • Stop everything:   ${BOLD}cd \"${WORK_DIR}\" && ${CLI_HINT} stop${RESET}"
say "  • Start it again:    ${BOLD}cd \"${WORK_DIR}\" && ${CLI_HINT} start${RESET}"
say "  • Get updates:       ${BOLD}cd \"${WORK_DIR}\" && ${CLI_HINT} pull && ${CLI_HINT} up -d${RESET}"
say "  • View logs:         ${BOLD}cd \"${WORK_DIR}\" && ${CLI_HINT} logs -f${RESET}"
say "  • Reconfigure:       ${BOLD}${RETRY_HINT}${RESET} ${DIM}(choose 'start over' when asked)${RESET}"
say
say "Everything lives in ${BOLD}${WORK_DIR}${RESET} — your conversations and"
say "settings stay on this Mac."

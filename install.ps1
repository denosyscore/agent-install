#!/usr/bin/env pwsh
# install.ps1 — one-command installer for the Telegram agent (Windows, Docker).
#
# Self-contained: pulls ready-made multi-arch images from GHCR, asks a few
# questions, writes a config file, and starts everything with Docker Desktop.
#
# Run it with, in PowerShell:
#   irm <the link they gave you> | iex
# or, if you saved the file:
#   .\install.ps1
#
# Re-running is safe — it picks up where it makes sense and won't duplicate.
#
# If an existing WSL2 distro already runs Docker, this script offers to run the
# Linux installer (install.sh) inside WSL instead of the native Windows path.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Canonical URL of install.sh in the public mirror (denosyscore/agent-install).
# The WSL2 fallback fetches and runs it inside WSL. Mirrored automatically from
# the private source on each release — see docs/install.md.
$InstallShUrl = 'https://raw.githubusercontent.com/denosyscore/agent-install/main/install.sh'

$WorkDir     = Join-Path $HOME 'telegram-agent'
$ComposeFile = 'docker-compose.yml'
$EnvFile     = '.env'

function Say  { param([string]$m='') Write-Host $m }
function Info { param([string]$m) Write-Host "> $m"  -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host "OK $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "!  $m" -ForegroundColor Yellow }
function Fail { param([string]$m) Write-Host "X  $m" -ForegroundColor Red }
function Rule { Write-Host ('-' * 56) -ForegroundColor DarkGray }

function Read-Secret {
  param([string]$Prompt)
  $secure = Read-Host -Prompt $Prompt -AsSecureString
  $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-NonEmpty {
  param([string]$Prompt,[string]$Pattern='',[string]$Hint='',[switch]$Secret)
  while ($true) {
    $v = if ($Secret) { Read-Secret $Prompt } else { Read-Host -Prompt $Prompt }
    if ([string]::IsNullOrWhiteSpace($v)) { Warn 'That was empty — please paste the value and press Enter.'; continue }
    if ($Pattern -and ($v -notmatch $Pattern)) { Warn "That doesn't look right. $Hint"; continue }
    return $v
  }
}

function Test-DockerInstalled { [bool](Get-Command docker -ErrorAction SilentlyContinue) }
function Test-DockerRunning   { docker info *> $null; return ($LASTEXITCODE -eq 0) }

function New-Secret32 {
  # 32 random bytes as 64 hex chars — the openssl-rand-hex-32 equivalent.
  $bytes = New-Object 'System.Byte[]' 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

# ── intro ──────────────────────────────────────────────────────────────────
Rule
Say 'Telegram Agent — Installer (Windows)'
Rule
Say 'This sets up a personal Claude-powered assistant you talk to through'
Say 'Telegram, running on this PC inside Docker.'
Say ''
Say 'First run typically takes 15-30 minutes, most of which is Docker'
Say 'downloading ~4 GB of images in the background. It will ask you for:'
Say '  * A Telegram bot token (free, from @BotFather)'
Say '  * Your personal Telegram user ID (free, from @userinfobot)'
Say '  * Either a Claude Pro/Max subscription OR an Anthropic API key'
Say ''
Say "Files will be kept in: $WorkDir"
Rule
Read-Host 'Press Enter to begin (or Ctrl+C to cancel)' | Out-Null
Say ''

# ── WSL2-with-Docker fallback ───────────────────────────────────────────────
$wslHasDocker = $false
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
  try {
    wsl.exe -e sh -c 'command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1' *> $null
    if ($LASTEXITCODE -eq 0) { $wslHasDocker = $true }
  } catch { $wslHasDocker = $false }
}
if ($wslHasDocker) {
  Info 'Detected a WSL2 environment that already runs Docker.'
  Say  'You can install inside WSL using the Linux installer (recommended if'
  Say  'your Docker lives in WSL), or continue with the native Windows path.'
  $useWsl = Read-Host 'Install inside WSL with the Linux script? [Y/n]'
  if ([string]::IsNullOrWhiteSpace($useWsl) -or $useWsl -match '^[Yy]') {
    if ($InstallShUrl) {
      Info 'Handing off to install.sh inside WSL...'
      wsl.exe -e bash -c "curl -fsSL '$InstallShUrl' | bash"
      exit $LASTEXITCODE
    } else {
      Warn 'No install.sh URL is baked into this script, so it cannot auto-run.'
      Say  'Open your WSL distro and run the Linux one-liner your operator gave'
      Say  'you (curl -fsSL <url> | bash), or continue here for the native path.'
      Read-Host 'Press Enter to continue with the native Windows install' | Out-Null
    }
  }
}

# ── Docker preflight ────────────────────────────────────────────────────────
Info 'Checking Docker...'
if (-not (Test-DockerInstalled)) {
  Warn "Docker isn't installed yet. Docker Desktop is the free tool this agent"
  Warn 'runs inside of.'
  Say  ''
  Say  'Opening the Docker Desktop download page...'
  Start-Process 'https://www.docker.com/products/docker-desktop/' | Out-Null
  Say  ''
  Say  'What to do:'
  Say  '  1. Download and install Docker Desktop for Windows.'
  Say  '  2. Launch it and wait until it reports "Engine running".'
  Say  '     (Docker Desktop enables the WSL2 backend it needs on first run.)'
  Say  ''
  Read-Host 'Press Enter once Docker Desktop is installed and running' | Out-Null
}

Info 'Waiting for Docker to be ready (can take a minute the first time)...'
$attempts = 0
while (-not (Test-DockerRunning)) {
  $attempts++
  if ($attempts -ge 60) {
    Fail "Docker still isn't responding after a few minutes."
    Say  'Open Docker Desktop, wait until it says "Engine running", then re-run'
    Say  'this installer.'
    exit 1
  }
  if ($attempts -eq 1) {
    $dd = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path $dd) { Start-Process $dd | Out-Null }
  }
  Start-Sleep -Seconds 3
}
Ok 'Docker is running.'
Say ''

# ── working dir + disk preflight ────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Set-Location $WorkDir
Info "Working in $WorkDir"
foreach ($d in 'volumes/claude-data','volumes/data','volumes/whisper-cache','volumes/embeddings-cache') {
  New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir $d) | Out-Null
}
try {
  $drive     = (Get-Item $WorkDir).PSDrive.Name
  $freeGb    = [math]::Floor((Get-PSDrive $drive).Free / 1GB)
  $requiredGb = 15
  if ($freeGb -lt $requiredGb) {
    Warn "Low disk space: about $freeGb GB free on ${drive}:, but the images need"
    Warn "roughly $requiredGb GB (they download ~4 GB and unpack to ~14 GB)."
    $cont = Read-Host 'Continue anyway? [y/N]'
    if ($cont -notmatch '^[Yy]') { Fail 'Stopped so you can free up disk space first.'; exit 1 }
  } else {
    Ok "Disk space looks fine (~$freeGb GB free)."
  }
} catch { }
Say ''

# ── reuse existing config? ──────────────────────────────────────────────────
$reconfigure = $true
$scopeProfile = ''
if (Test-Path $EnvFile) {
  Say "It looks like this agent is already set up here (found an existing $EnvFile)."
  Say '  1) Keep my existing settings and just make sure everything is running'
  Say '  2) Start over and reconfigure from scratch'
  $reuse = Read-Host 'Choose 1 or 2 [1]'; if ([string]::IsNullOrWhiteSpace($reuse)) { $reuse = '1' }
  if ($reuse -eq '1') {
    $reconfigure = $false
    Ok 'Reusing existing configuration.'
    $line = (Select-String -Path $EnvFile -Pattern '^INSTALL_SCOPE_PROFILE=' | Select-Object -Last 1)
    if ($line) { $scopeProfile = ($line.Line -replace '^INSTALL_SCOPE_PROFILE=', '') }
  } else {
    Copy-Item $EnvFile "$EnvFile.bak.$(Get-Date -Format yyyyMMddHHmmss)"
    Say 'Backed up your old settings.'
  }
  Say ''
}

# ── scope menu + credentials ────────────────────────────────────────────────
$botToken = ''; $allowedIds = ''; $apiKey = ''; $oauthToken = ''
$bridgeSecret = ''; $workerSecret = ''
if ($reconfigure) {
  Say 'What would you like to run?'
  Say '  1) Just the bot (recommended)'
  Say '  2) Bot + web admin panel (dashboard at http://localhost:8080)'
  Say '  3) Everything (adds admin + optional TickTick — needs your own tokens)'
  $scope = Read-Host 'Choose 1, 2, or 3 [1]'; if ([string]::IsNullOrWhiteSpace($scope)) { $scope = '1' }
  switch ($scope) {
    '2' { $scopeProfile = 'admin' }
    '3' { $scopeProfile = 'everything'
          Warn "TickTick won't do anything until you add TICKTICK_ACCESS_TOKEN to .env afterwards." }
    default { $scopeProfile = '' }
  }
  Say ''

  Rule
  Say 'Step 1 of 4 - Telegram bot'
  Say 'Create a bot with @BotFather in Telegram (/newbot), then paste its token.'
  $botToken = Read-NonEmpty 'Paste your bot token' '^[0-9]+:[A-Za-z0-9_-]+$' `
    'It should look like 123456789:ABCdef... (numbers, a colon, then letters/numbers).' -Secret
  Ok 'Bot token looks good.'
  Say ''

  Rule
  Say 'Step 2 of 4 - Your Telegram ID'
  Say 'Message @userinfobot in Telegram; it replies with your numeric Id.'
  $allowedIds = Read-NonEmpty 'Paste your numeric Telegram ID' '^[0-9]+$' 'It should be digits only, e.g. 123456789.'
  Ok 'Got it.'
  Say ''

  Rule
  Say 'Step 3 of 4 - Claude access'
  Say '  1) I have a Claude Pro or Max subscription'
  Say '  2) I have (or will create) an Anthropic API key'
  $claude = Read-Host 'Choose 1 or 2 [1]'; if ([string]::IsNullOrWhiteSpace($claude)) { $claude = '1' }
  Say ''
  if ($claude -eq '2') {
    Say 'Create an API key at https://console.anthropic.com (Settings -> API Keys),'
    Say 'with billing enabled. It starts with sk-ant-.'
    $apiKey = Read-NonEmpty 'Paste your API key' '^sk-ant-' 'It should start with sk-ant-.' -Secret
    Ok 'API key looks good.'
  } else {
    Say 'This uses your Claude Pro/Max subscription via the Claude CLI setup-token.'
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
      Say 'The Claude CLI is not installed. Install it, then come back:'
      Say '  irm https://claude.ai/install.ps1 | iex'
      Say 'After installing, run:  claude setup-token'
      Say 'and copy the long token it prints.'
      $oauthToken = Read-NonEmpty 'Paste the token from "claude setup-token"' '' '' -Secret
    } else {
      Say 'Running "claude setup-token" — it opens your browser to log in.'
      try { claude setup-token } catch { Warn 'setup-token did not complete; you can run it yourself: claude setup-token' }
      $oauthToken = Read-NonEmpty 'Paste the token from "claude setup-token"' '' '' -Secret
    }
    Ok 'Claude subscription token captured.'
  }
  Say ''

  Rule
  Say 'Step 4 of 4 - Security keys'
  Say 'Generating two random internal secrets (you never type these)...'
  $bridgeSecret = New-Secret32
  $workerSecret = New-Secret32
  Ok 'Security keys generated.'
  Say ''
}

# ── write .env ──────────────────────────────────────────────────────────────
if ($reconfigure) {
  Info "Writing configuration to $EnvFile..."
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Written by install.ps1 on $(Get-Date)")
  $lines.Add("# This file holds your secrets. Don't share it or commit it anywhere.")
  $lines.Add('')
  $lines.Add("TELEGRAM_BOT_TOKEN=$botToken")
  $lines.Add("ALLOWED_USER_IDS=$allowedIds")
  $lines.Add('')
  if ($apiKey) { $lines.Add("ANTHROPIC_API_KEY=$apiKey") }
  else { $lines.Add('# ANTHROPIC_API_KEY=  (left unset — using a Claude subscription instead)') }
  if ($oauthToken) { $lines.Add("CLAUDE_CODE_OAUTH_TOKEN=$oauthToken") }
  else { $lines.Add('# CLAUDE_CODE_OAUTH_TOKEN=  (left unset — using an API key instead)') }
  $lines.Add('')
  $lines.Add("BRIDGE_CONTROL_SECRET=$bridgeSecret")
  $lines.Add("WORKER_CONTROL_SECRET=$workerSecret")
  $lines.Add('')
  $lines.Add('# Remembers your menu choice so re-running this script does not ask again.')
  $lines.Add("INSTALL_SCOPE_PROFILE=$scopeProfile")
  $lines.Add('')
  $lines.Add('# --- Sane defaults; edit if you know what you are doing ---')
  $lines.Add('RATE_LIMIT_HOURLY=30')
  $lines.Add('RATE_LIMIT_DAILY=200')
  $lines.Add('DB_PATH=data/sessions.db')
  $lines.Add('WHISPER_URL=http://whisper:9000')
  $lines.Add('WHISPER_MODEL=base.en')
  $lines.Add('WHISPER_ENGINE=faster_whisper')
  $lines.Add('EMBEDDINGS_URL=http://embeddings:80')
  $lines.Add('EMBEDDINGS_MODEL=BAAI/bge-small-en-v1.5')
  $lines.Add('LANCE_DB_PATH=/app/data/lance')
  $lines.Add('RAG_AUTO_PRUNE=true')
  $lines.Add('RAG_PRUNE_DAYS=90')
  $lines.Add('ADMIN_PORT=8080')
  $lines.Add('')
  $lines.Add('# --- Optional TickTick integration (only used under scope "Everything") ---')
  $lines.Add('# TICKTICK_ACCESS_TOKEN=')
  $lines.Add('# TICKTICK_V2_SESSION_TOKEN=')
  # UTF-8 without BOM so docker/compose parse it cleanly.
  [System.IO.File]::WriteAllLines((Join-Path $WorkDir $EnvFile), $lines, (New-Object System.Text.UTF8Encoding($false)))
  Ok "Configuration saved to $WorkDir\$EnvFile."
  Say ''
}

# ── write compose (identical services to install.sh; embeddings pinned amd64) ─
Info 'Writing Docker configuration...'
$compose = @'
# Written by install.ps1 — pulls pre-built images, no source/build needed.
# See docker-compose.install.yml in the agent repo for the annotated version.
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
'@
[System.IO.File]::WriteAllText((Join-Path $WorkDir $ComposeFile), $compose, (New-Object System.Text.UTF8Encoding($false)))
Ok 'Docker configuration written.'
Say ''

# ── pull + start ────────────────────────────────────────────────────────────
$profileArgs = @()
if ($scopeProfile) { $profileArgs = @('--profile', $scopeProfile) }

Rule
Say 'Downloading and starting the agent...'
Say 'This downloads the pre-built images (~4 GB the first time, unpacking to'
Say '~14 GB on disk). It can take several minutes to half an hour.'
Say ''
docker compose @profileArgs pull
if ($LASTEXITCODE -ne 0) {
  Fail 'Downloading the images failed.'
  Say  'Check your internet connection and re-run. If it keeps failing, the'
  Say  'images may not be public yet — ask whoever gave you this installer.'
  exit 1
}
Ok 'Images downloaded.'
Say ''

Info 'Starting containers...'
docker compose @profileArgs up -d
if ($LASTEXITCODE -ne 0) {
  Fail 'Starting the containers failed.'
  Say  "Re-run the installer, or inspect logs with: docker compose logs"
  exit 1
}
Ok 'Containers started.'
Say ''

# ── verify ──────────────────────────────────────────────────────────────────
Info 'Waiting for the bot to finish starting up...'
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
  $running = (docker compose ps --status running --services 2>$null)
  if ($running -match '(?m)^bridge$') {
    $logs = (docker compose logs bridge 2>$null | Out-String)
    if ($logs -match 'allowlist|listening|ready|started') { $ready = $true; break }
  }
  Start-Sleep -Seconds 3
}

Say ''
Rule
if ($ready) {
  Ok 'Your agent is running!'
  Say ''
  Say 'Open Telegram, find the bot you created with @BotFather, and say hi.'
  if ($scopeProfile -eq 'admin' -or $scopeProfile -eq 'everything') {
    Say 'Admin panel: http://localhost:8080'
  }
  if ($scopeProfile -eq 'everything') {
    Say "TickTick is running but idle until you add your TickTick token to .env."
  }
} else {
  Warn "The containers started, but the bot isn't confirmed ready yet."
  Say  'It may just need more time (Whisper/embeddings warm up on first run).'
  Say  'Message your bot now; if it does not respond in a few minutes, check:'
  Say  "  docker compose logs bridge"
}
Rule
Say ''
Say 'Good to know (run these from the install folder):'
Say "  cd `"$WorkDir`""
Say '  Stop:     docker compose stop'
Say '  Start:    docker compose start'
Say '  Update:   docker compose pull; docker compose up -d'
Say '  Logs:     docker compose logs -f'
Say ''
Say "Everything lives in $WorkDir — your conversations and settings stay on this PC."

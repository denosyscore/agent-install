#!/usr/bin/env pwsh
# install.ps1 — one-command installer for the Telegram agent (Windows).
#
# Self-contained: pulls ready-made multi-arch images from GHCR, asks a few
# questions, generates a config from your feature selection, and starts
# everything with your chosen runtime (Docker Desktop or Podman).
#
# Run it with, in PowerShell:
#   irm <the link they gave you> | iex
# or, if you saved the file:
#   .\install.ps1
#
# Re-running is safe — it picks up where it makes sense and won't duplicate.
# If an existing WSL2 distro already runs Docker, this script offers to run the
# Linux installer (install.sh) inside WSL instead of the native Windows path.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Canonical URL of install.sh in the public mirror (denosyscore/agent-install),
# used by the WSL2 fallback. Mirrored automatically from the private source.
$InstallShUrl = 'https://raw.githubusercontent.com/denosyscore/agent-install/main/install.sh'

$WorkDir     = Join-Path $HOME 'telegram-agent'
$ComposeFile = 'docker-compose.yml'
$EnvFile     = '.env'
$Runtime     = 'docker'   # set by Select-Runtime
$CliHint     = 'docker compose'

function Say  { param([string]$m='') Write-Host $m }
function Info { param([string]$m) Write-Host "> $m"  -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host "OK $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "!  $m" -ForegroundColor Yellow }
function Fail { param([string]$m) Write-Host "X  $m" -ForegroundColor Red }
function Rule { Write-Host ('-' * 56) -ForegroundColor DarkGray }
function Have { param([string]$c) [bool](Get-Command $c -ErrorAction SilentlyContinue) }

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

# Read-Optional — a single secret read that ALLOWS blank (paste now or add later).
function Read-Optional { param([string]$Prompt) Read-Secret $Prompt }

# Read-YesNo — returns $true/$false; Enter keeps the default.
function Read-YesNo {
  param([string]$Q,[bool]$Default)
  $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
  $a = Read-Host "  $Q $hint"
  if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
  return ($a -match '^[Yy]')
}

function New-Secret32 {
  $bytes = New-Object 'System.Byte[]' 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

# ── runtime abstraction ──────────────────────────────────────────────────────
# Windows offers Docker (Desktop) or Podman (machine). Colima is macOS/Linux only.
function Runtime-Ready {
  if ($Runtime -eq 'podman') { podman info *> $null } else { docker info *> $null }
  return ($LASTEXITCODE -eq 0)
}
function Compose {
  if ($Runtime -eq 'podman') {
    if ($FeatExec -and (Test-Path (Join-Path $WorkDir 'docker-compose.podman.yml'))) {
      podman compose -f docker-compose.yml -f docker-compose.podman.yml @args
    } else { podman compose @args }
  } else { docker compose @args }
}
function Wait-Runtime {
  Info "Waiting for $Runtime to be ready (can take a minute the first time)..."
  for ($i = 0; $i -lt 60; $i++) { if (Runtime-Ready) { return }; Start-Sleep -Seconds 3 }
  Fail "$Runtime still isn't responding. Start it and re-run this installer."; exit 1
}
function Ensure-Docker {
  if (-not (Have docker)) {
    Warn "Docker isn't installed. Opening the Docker Desktop download page..."
    Start-Process 'https://www.docker.com/products/docker-desktop/' | Out-Null
    Say 'Install Docker Desktop for Windows, launch it (wait for "Engine running").'
    Read-Host 'Press Enter once Docker Desktop is installed and running' | Out-Null
  }
  if (-not (Runtime-Ready)) {
    $dd = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path $dd) { Start-Process $dd | Out-Null }
  }
  Wait-Runtime
}
function Ensure-Podman {
  if (-not (Have podman)) {
    Fail "Podman isn't installed. Install Podman for Windows, then re-run:"
    Say  '  https://podman.io/docs/installation'
    exit 1
  }
  podman machine inspect *> $null
  if ($LASTEXITCODE -ne 0) { Info 'Initializing the Podman machine...'; podman machine init --cpus 4 --memory 8192 --disk-size 30 }
  if (-not (Runtime-Ready)) { Info 'Starting the Podman machine...'; podman machine start }
  Wait-Runtime
}
function Select-Runtime {
  $installed = @()
  if (Have docker) { $installed += 'docker' }
  if (Have podman) { $installed += 'podman' }
  if ($installed.Count -eq 1) {
    $script:Runtime = $installed[0]
    Ok "Using $($script:Runtime) (the container runtime found on this PC)."
  } else {
    Say 'How do you want to run the containers?'
    Say '  1) Docker (Docker Desktop for Windows)'
    Say '  2) Podman (daemonless, no Docker Desktop)'
    $c = Read-Host 'Choose 1 or 2 [1]'
    $script:Runtime = if ($c -eq '2') { 'podman' } else { 'docker' }
  }
  $script:CliHint = if ($script:Runtime -eq 'podman') { 'podman compose' } else { 'docker compose' }
}

# ── intro ──────────────────────────────────────────────────────────────────
Rule
Say 'Telegram Agent — Installer (Windows)'
Rule
Say 'This sets up a personal Claude-powered assistant you talk to through'
Say 'Telegram, running on this PC in containers.'
Say ''
Say 'First run typically takes 15-30 minutes, most of which is the runtime'
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
if (Have wsl.exe) {
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
    Info 'Handing off to install.sh inside WSL...'
    wsl.exe -e bash -c "curl -fsSL '$InstallShUrl' | bash"
    exit $LASTEXITCODE
  }
}

# ── runtime preflight ───────────────────────────────────────────────────────
Select-Runtime
if ($Runtime -eq 'podman') { Ensure-Podman } else { Ensure-Docker }
Ok "$Runtime is ready."
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

# ── feature flags ───────────────────────────────────────────────────────────
$FeatVoice=$false; $FeatRag=$false; $FeatExec=$false; $FeatAdmin=$false
$FeatGithub=$false; $FeatNotion=$false; $FeatBrave=$false; $FeatWeather=$false; $FeatNews=$false
$FeatGmail=$false; $FeatSpotify=$false; $FeatTicktick=$false; $FeatBash=$false
$GithubTok=''; $NotionTok=''; $BraveKey=''

function Apply-Preset {
  param([string]$p)
  switch ($p) {
    'recommended' { $script:FeatVoice=$true; $script:FeatRag=$true; $script:FeatExec=$true }
    'everything'  { $script:FeatVoice=$true; $script:FeatRag=$true; $script:FeatExec=$true; $script:FeatAdmin=$true
                    $script:FeatWeather=$true; $script:FeatNews=$true
                    $script:FeatGithub=$true; $script:FeatNotion=$true; $script:FeatBrave=$true
                    $script:FeatGmail=$true; $script:FeatSpotify=$true; $script:FeatTicktick=$true }
    'minimal'     { }
  }
}

# ── reuse existing config? ──────────────────────────────────────────────────
$reconfigure = $true
if (Test-Path $EnvFile) {
  Say "It looks like this agent is already set up here (found an existing $EnvFile)."
  Say '  1) Keep my existing settings and just make sure everything is running'
  Say '  2) Start over and reconfigure from scratch'
  $reuse = Read-Host 'Choose 1 or 2 [1]'; if ([string]::IsNullOrWhiteSpace($reuse)) { $reuse = '1' }
  if ($reuse -eq '1') {
    $reconfigure = $false
    Ok 'Reusing existing configuration.'
    if (Test-Path '.install-manifest') {
      foreach ($ln in (Get-Content '.install-manifest')) {
        if ($ln -match '^(FEAT_[A-Z]+)=([01])$') {
          Set-Variable -Name ($matches[1] -replace '^FEAT_','Feat' -replace '_','') -Value ($matches[2] -eq '1') -Scope Script
        }
      }
    }
  } else {
    Copy-Item $EnvFile "$EnvFile.bak.$(Get-Date -Format yyyyMMddHHmmss)"
    Say 'Backed up your old settings.'
  }
  Say ''
}

# ── feature selection + credentials ─────────────────────────────────────────
$botToken=''; $allowedIds=''; $apiKey=''; $oauthToken=''; $bridgeSecret=''; $workerSecret=''
if ($reconfigure) {
  Say 'What would you like to install?'
  Say '  1) Recommended (chat + voice + memory/RAG + code execution)'
  Say '  2) Everything  (adds admin panel + all integrations)'
  Say '  3) Minimal     (chat only)'
  Say '  4) Customize   (choose each capability + integration)'
  $preset = Read-Host 'Choose 1-4 [1]'
  switch ($preset) {
    '2' { Apply-Preset 'everything' }
    '3' { Apply-Preset 'minimal' }
    '4' {
      Apply-Preset 'recommended'
      Say ''; Say 'Capabilities (press Enter to keep the shown default):'
      $FeatVoice = Read-YesNo 'Voice messages (Whisper transcription)?' $FeatVoice
      $FeatRag   = Read-YesNo 'Semantic memory / search of past chats (RAG)?' $FeatRag
      $FeatExec  = Read-YesNo 'Code execution (sandboxed)?' $FeatExec
      $FeatAdmin = Read-YesNo 'Web admin dashboard?' $FeatAdmin
      Say ''; Say 'Integrations:'
      $FeatGithub  = Read-YesNo 'GitHub (needs a token)?' $FeatGithub
      $FeatNotion  = Read-YesNo 'Notion (needs a token)?' $FeatNotion
      $FeatBrave   = Read-YesNo 'Brave Search (needs a key)?' $FeatBrave
      $FeatWeather = Read-YesNo 'Weather (free)?' $FeatWeather
      $FeatNews    = Read-YesNo 'News / GDELT (free)?' $FeatNews
      $FeatGmail   = Read-YesNo 'Gmail (OAuth — set up after install)?' $FeatGmail
      $FeatSpotify = Read-YesNo 'Spotify (OAuth — set up after install)?' $FeatSpotify
      $FeatTicktick= Read-YesNo 'TickTick (OAuth — set up after install)?' $FeatTicktick
      Say ''; Say 'Advanced:'
      Warn 'The Bash tool lets Claude run shell commands in the container. If the'
      Warn 'bot is ever prompt-injected, that can read env vars or exfiltrate data.'
      $FeatBash = Read-YesNo 'Enable the Bash tool (leave off unless you need it)?' $FeatBash
    }
    default { Apply-Preset 'recommended' }
  }
  Say ''
  if ($FeatGithub) { $GithubTok = Read-Optional 'Paste a GitHub token (blank = add to .env later): ' }
  if ($FeatNotion) { $NotionTok = Read-Optional 'Paste a Notion token (blank = add later): ' }
  if ($FeatBrave)  { $BraveKey  = Read-Optional 'Paste a Brave Search key (blank = add later): ' }

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
    if (-not (Have claude)) {
      Say 'The Claude CLI is not installed. Install it, then come back:'
      Say '  irm https://claude.ai/install.ps1 | iex'
      Say 'After installing, run:  claude setup-token  and copy the long token.'
      $oauthToken = Read-NonEmpty 'Paste the token from "claude setup-token"' '' '' -Secret
    } else {
      Say 'Running "claude setup-token" — it opens your browser to log in.'
      try { claude setup-token } catch { Warn 'setup-token did not complete; run it yourself: claude setup-token' }
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
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add("# Written by install.ps1 on $(Get-Date). Holds secrets - do not share/commit.")
  $L.Add('')
  $L.Add("TELEGRAM_BOT_TOKEN=$botToken")
  $L.Add("ALLOWED_USER_IDS=$allowedIds")
  $L.Add('')
  if ($apiKey) { $L.Add("ANTHROPIC_API_KEY=$apiKey") } else { $L.Add('# ANTHROPIC_API_KEY=  (using a Claude subscription)') }
  if ($oauthToken) { $L.Add("CLAUDE_CODE_OAUTH_TOKEN=$oauthToken") } else { $L.Add('# CLAUDE_CODE_OAUTH_TOKEN=  (using an API key)') }
  $L.Add('')
  $L.Add("BRIDGE_CONTROL_SECRET=$bridgeSecret")
  $L.Add("WORKER_CONTROL_SECRET=$workerSecret")
  $L.Add('')
  $L.Add('# --- Defaults ---')
  $L.Add('RATE_LIMIT_HOURLY=30')
  $L.Add('RATE_LIMIT_DAILY=200')
  $L.Add('DB_PATH=data/sessions.db')
  if ($FeatVoice) { $L.Add('WHISPER_URL=http://whisper:9000') } else { $L.Add('WHISPER_URL=') }
  $L.Add('WHISPER_MODEL=base.en')
  $L.Add('WHISPER_ENGINE=faster_whisper')
  if ($FeatRag) { $L.Add('EMBEDDINGS_URL=http://embeddings:80') } else { $L.Add('EMBEDDINGS_URL=') }
  $L.Add('EMBEDDINGS_MODEL=BAAI/bge-small-en-v1.5')
  $L.Add('LANCE_DB_PATH=/app/data/lance')
  $L.Add('RAG_AUTO_PRUNE=true')
  $L.Add('RAG_PRUNE_DAYS=90')
  $L.Add('ADMIN_PORT=8080')
  if ($FeatBash) { $L.Add('ENABLE_BASH=true') }
  $L.Add('')
  $L.Add('# --- Integrations ---')
  if ($FeatWeather) { $L.Add('ENABLE_WEATHER_MCP=true') }
  if ($FeatNews)    { $L.Add('ENABLE_NEWS_MCP=true') }
  if ($FeatGithub)  { if ($GithubTok) { $L.Add("GITHUB_TOKEN=$GithubTok") } else { $L.Add('# GITHUB_TOKEN=  (enabled - paste your token here to activate)') } }
  if ($FeatNotion)  { if ($NotionTok) { $L.Add("NOTION_TOKEN=$NotionTok") } else { $L.Add('# NOTION_TOKEN=  (enabled - paste your token here)') } }
  if ($FeatBrave)   { if ($BraveKey)  { $L.Add("BRAVE_API_KEY=$BraveKey") } else { $L.Add('# BRAVE_API_KEY=  (enabled - paste your key here)') } }
  if ($FeatGmail)   { $L.Add('GMAIL_OAUTH_PATH=/app/data/gmail/gcp-oauth.keys.json'); $L.Add('GMAIL_CREDENTIALS_PATH=/app/data/gmail/credentials.json') }
  if ($FeatSpotify) { $L.Add('# SPOTIFY_CLIENT_ID='); $L.Add('# SPOTIFY_CLIENT_SECRET='); $L.Add('# SPOTIFY_REFRESH_TOKEN=') }
  if ($FeatTicktick){ $L.Add('# TICKTICK_ACCESS_TOKEN='); $L.Add('# TICKTICK_V2_SESSION_TOKEN=') }
  [System.IO.File]::WriteAllLines((Join-Path $WorkDir $EnvFile), $L, (New-Object System.Text.UTF8Encoding($false)))

  # Feature manifest (kept OUT of .env) so keep-settings re-runs match.
  $man = New-Object System.Collections.Generic.List[string]
  $man.Add('# Written by install.ps1 - your feature selection.')
  $pairs = [ordered]@{
    FEAT_VOICE=$FeatVoice; FEAT_RAG=$FeatRag; FEAT_EXEC=$FeatExec; FEAT_ADMIN=$FeatAdmin
    FEAT_GITHUB=$FeatGithub; FEAT_NOTION=$FeatNotion; FEAT_BRAVE=$FeatBrave
    FEAT_WEATHER=$FeatWeather; FEAT_NEWS=$FeatNews; FEAT_GMAIL=$FeatGmail
    FEAT_SPOTIFY=$FeatSpotify; FEAT_TICKTICK=$FeatTicktick; FEAT_BASH=$FeatBash
  }
  foreach ($k in $pairs.Keys) { $man.Add("$k=$([int][bool]$pairs[$k])") }
  [System.IO.File]::WriteAllLines((Join-Path $WorkDir '.install-manifest'), $man, (New-Object System.Text.UTF8Encoding($false)))
  Ok "Configuration saved to $WorkDir\$EnvFile."
  Say ''
}

# ── generate compose from the feature flags ─────────────────────────────────
Info "Writing container configuration for $Runtime..."
$c = New-Object System.Collections.Generic.List[string]
$c.Add("# Written by install.ps1 for $Runtime. Generated from your feature selection.")
$c.Add('services:')
$c.Add('  bridge:')
$c.Add('    image: ghcr.io/denosyscore/agent-bridge:latest')
$c.Add('    container_name: tg-claude-bridge')
$c.Add('    restart: unless-stopped')
$c.Add('    env_file: .env')
$c.Add('    environment:')
$c.Add('      WORKER_CONTROL_SECRET: ${WORKER_CONTROL_SECRET}')
if ($FeatRag)      { $c.Add('      WORKER_URL: http://reindexer:7012') }
if ($FeatExec)     { $c.Add('      EXECUTOR_URL: http://executor:7014') }
if ($FeatTicktick) { $c.Add('      TICKTICK_MCP_URL: http://ticktick-mcp:7013') }
if ($FeatVoice -or $FeatRag) {
  $c.Add('    depends_on:')
  if ($FeatVoice) { $c.Add('      whisper:'); $c.Add('        condition: service_started') }
  if ($FeatRag)   { $c.Add('      embeddings:'); $c.Add('        condition: service_started') }
}
$c.Add('    volumes:')
$c.Add('      - ./volumes/claude-data:/home/bot/.claude')
$c.Add('      - ./volumes/data:/app/data')
$c.Add('    networks:')
$c.Add('      - default')
if ($FeatExec) { $c.Add('      - execnet') }
$c.Add('    init: true')
$c.Add('    stop_grace_period: 30s')
$c.Add('    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }')

if ($FeatRag) {
  $c.Add(@'

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
    platform: linux/amd64
    container_name: tg-claude-embeddings
    restart: unless-stopped
    command: --model-id ${EMBEDDINGS_MODEL:-BAAI/bge-small-en-v1.5}
    volumes:
      - ./volumes/embeddings-cache:/data
    deploy: { resources: { limits: { memory: 1500M } } }
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
'@)
}
if ($FeatExec) {
  $c.Add(@'

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
'@)
}
if ($FeatVoice) {
  $c.Add(@'

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
'@)
}
if ($FeatAdmin) {
  $c.Add(@'

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
'@)
}
if ($FeatTicktick) {
  $c.Add(@'

  ticktick-mcp:
    image: ghcr.io/denosyscore/agent-ticktick-mcp:latest
    container_name: tg-claude-ticktick-mcp
    restart: unless-stopped
    env_file: .env
    environment:
      TICKTICK_ACCESS_TOKEN: ${TICKTICK_ACCESS_TOKEN:-}
      TICKTICK_V2_SESSION_TOKEN: ${TICKTICK_V2_SESSION_TOKEN:-}
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
'@)
}
if ($FeatExec) {
  $c.Add("`nnetworks:`n  execnet:`n    internal: true")
}
[System.IO.File]::WriteAllText((Join-Path $WorkDir $ComposeFile), ($c -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))

# Podman + code execution: write the executor override (compose() layers it).
if ($Runtime -eq 'podman' -and $FeatExec) {
  $ov = @'
services:
  executor:
    security_opt:
      - label=disable
    annotations:
      run.oci.keep_original_groups: "1"
    userns_mode: keep-id
'@
  [System.IO.File]::WriteAllText((Join-Path $WorkDir 'docker-compose.podman.yml'), $ov, (New-Object System.Text.UTF8Encoding($false)))
}
Ok 'Container configuration written.'
Say ''

# ── pull + start ────────────────────────────────────────────────────────────
Rule
Say 'Downloading and starting the agent...'
Say 'This downloads the pre-built images (~4 GB the first time, unpacking to'
Say '~14 GB on disk). It can take several minutes to half an hour.'
Say ''
Compose pull
if ($LASTEXITCODE -ne 0) {
  Fail 'Downloading the images failed.'
  Say  'Check your internet connection and re-run. If it keeps failing, the'
  Say  'images may not be public yet — ask whoever gave you this installer.'
  exit 1
}
Ok 'Images downloaded.'
Say ''

Info 'Starting containers...'
Compose up -d
if ($LASTEXITCODE -ne 0) {
  Fail 'Starting the containers failed.'
  Say  "Re-run the installer, or inspect logs with: $CliHint logs"
  exit 1
}
Ok 'Containers started.'
Say ''

# ── executor sandbox health (fail loud) ─────────────────────────────────────
if ($FeatExec) {
  Info 'Verifying the code-execution sandbox...'
  $execOk = $false
  for ($i = 0; $i -lt 20; $i++) {
    $running = (Compose ps --status running --services 2>$null)
    $log = (Compose logs executor 2>$null | Out-String)
    if (($running -match '(?m)^executor$') -and ($log -notmatch 'sandbox.*(fail|not operational|disabled)')) { $execOk = $true; break }
    if ($log -match 'self-test|sandbox') { break }
    Start-Sleep -Seconds 3
  }
  if (-not $execOk) {
    Warn 'The code-execution sandbox did not come up cleanly.'
    if ($Runtime -eq 'podman') {
      Say 'Rootless Podman can block the nested namespaces bubblewrap needs. Try a'
      Say 'rootful machine: podman machine set --rootful; podman machine stop; podman machine start'
      Say 'or re-run and choose Docker.'
    }
    Say "Full executor log: $CliHint logs executor"
    Fail 'Refusing to enable code execution unsandboxed. Fix the sandbox (above) and re-run, or turn off code execution when the menu asks.'
    exit 1
  }
  Ok 'Code-execution sandbox is healthy.'
  Say ''
}

# ── verify ──────────────────────────────────────────────────────────────────
Info 'Waiting for the bot to finish starting up...'
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
  $running = (Compose ps --status running --services 2>$null)
  if ($running -match '(?m)^bridge$') {
    $logs = (Compose logs bridge 2>$null | Out-String)
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
  if ($FeatAdmin) { Say 'Admin panel: http://localhost:8080' }
  if ($FeatTicktick) { Say 'TickTick is running but idle until you finish its OAuth setup and add the token to .env.' }
} else {
  Warn "The containers started, but the bot isn't confirmed ready yet."
  Say  'It may just need more time (Whisper/embeddings warm up on first run).'
  Say  "Message your bot now; if it does not respond in a few minutes, check: $CliHint logs bridge"
}
Rule
Say ''
Say 'Good to know (run these from the install folder):'
Say "  cd `"$WorkDir`""
Say "  Stop:     $CliHint stop"
Say "  Start:    $CliHint start"
Say "  Update:   $CliHint pull; $CliHint up -d"
Say "  Logs:     $CliHint logs -f"
Say ''
Say "Everything lives in $WorkDir — your conversations and settings stay on this PC."

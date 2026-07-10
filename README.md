# agent-install

One-command installer for a **self-hosted, Claude-powered personal AI agent** —
your own assistant that runs on your machine and that you talk to through Telegram.

It isn't a chatbot wrapper. It keeps long-term memory, recalls past conversations,
maintains a persona you shape, runs tasks on a schedule by itself, transcribes
voice, runs code, and can act across tools like GitHub and your task manager.
Telegram is just the interface.

The agent's source lives in a private repo; this repo is the public mirror of its
two install scripts so they can be fetched anonymously.

## Install

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/denosyscore/agent-install/main/install.sh | bash
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/denosyscore/agent-install/main/install.ps1 | iex
```

The installer asks a few questions (a Telegram bot token, your Telegram ID, and a
Claude Pro/Max subscription or an Anthropic API key), writes a local config, and
starts everything with Docker. It runs entirely on your machine — nothing leaves
it except your messages to Telegram and Anthropic.

## What you get

- **Talk to it on Telegram** — text, photos, and voice. Voice is transcribed
  locally by a Whisper sidecar; no third-party transcription service.
- **Long-term memory** — it remembers preferences, context, and facts about you
  across conversations and across restarts.
- **Semantic recall (RAG)** — every exchange is embedded and indexed locally, so
  it can search and pull up relevant past conversations on demand; old history is
  summarized into memory over time to stay lean.
- **A persona you shape** — a first-run conversation seeds its identity and a
  short dossier about you; it keeps working notes about itself. Everything is
  versioned and yours to edit or roll back.
- **Scheduled + recurring tasks** — "remind me about that PR in 2 hours" or "every
  weekday at 8am, summarize my last 24 hours" become real jobs it runs on its own,
  with full context, and DMs you the result.
- **Sandboxed code execution** — runs code snippets in an isolated executor,
  separate from the bot.
- **Optional web admin panel** — a local dashboard (installer menu option 2).
- **Optional integrations** — GitHub (the full API, via the official GitHub MCP)
  and TickTick, switched on by adding your own tokens.

Everything is local and self-hosted; you can stop or remove it at any time.

## Note

`install.sh` and `install.ps1` are **generated** — mirrored automatically from the
private source repo on each release. Don't edit them here; changes are overwritten
on the next sync.

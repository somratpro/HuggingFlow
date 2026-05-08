---
title: HuggingFlow
emoji: 🦌
colorFrom: green
colorTo: blue
sdk: docker
app_port: 7860
pinned: false
license: mit
secrets:
  - name: LLM_MODEL
    description: "Model in provider/model-name format — e.g. openai/gpt-4o, anthropic/claude-sonnet-4-5, google/gemini-2.5-flash"
  - name: LLM_API_KEY
    description: API key for the chosen LLM provider.
  - name: HF_TOKEN
    description: Hugging Face token (write access) — enables thread backup/restore to a private HF Dataset.
  - name: SERPER_API_KEY
    description: "Serper API key for real Google Search results (recommended). Free tier: 2,500 queries/month."
  - name: AUTH_JWT_SECRET
    description: "JWT signing secret — keeps sessions alive across restarts. Generate: openssl rand -base64 32"
  - name: CLOUDFLARE_WORKERS_TOKEN
    description: "Cloudflare API token — auto-creates an outbound proxy Worker and a keep-awake cron Worker."
---

<div align="center">

# 🦌 HuggingFlow

**[DeerFlow](https://github.com/bytedance/deer-flow) research agent — one-click deploy on Hugging Face Spaces**

[![HF Space](https://img.shields.io/badge/🤗%20Hugging%20Face-Space-yellow)](https://huggingface.co/spaces/somratpro/HuggingFlow)
[![GitHub](https://img.shields.io/badge/GitHub-somratpro%2FHuggingFlow-181717?logo=github)](https://github.com/somratpro/HuggingFlow)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Docker](https://img.shields.io/badge/docker-single--container-2496ED?logo=docker)](Dockerfile)

*Self-hosted deep-research AI · multi-provider LLM · streaming SSE · dataset backup*

</div>

---

## Table of Contents

- [What is HuggingFlow?](#what-is-huggingflow)
- [Features](#features)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
  - [Required Secrets](#required-secrets)
  - [Optional Variables](#optional-variables)
- [LLM Providers](#llm-providers)
- [Search Tools](#search-tools)
- [Cloudflare Proxy](#cloudflare-proxy)
- [Data Backup](#data-backup)
- [Stay Alive (Keep-Awake)](#stay-alive-keep-awake)
- [Architecture](#architecture)
- [Local Development](#local-development)
- [Troubleshooting](#troubleshooting)
- [More Projects](#more-projects)
- [Contributing](#contributing)
- [License](#license)

---

## What is HuggingFlow?

HuggingFlow wraps [DeerFlow](https://github.com/bytedance/deer-flow) (ByteDance's open-source deep-research agent) into a single Docker container that runs natively on [Hugging Face Spaces](https://huggingface.co/spaces).

**Zero infra.** Duplicate the Space, add your API keys, done — your own private research agent is live.

DeerFlow conducts multi-step research: it queries search engines, fetches web pages, synthesises findings across sources, and produces structured reports — all driven by the LLM you choose.

---

## Features

- 🚀 **One-click deploy** — duplicate the HF Space, add secrets, done
- 🧠 **Multi-provider LLM** — OpenAI, Anthropic, Google Gemini, DeepSeek, Groq, Mistral, xAI, OpenRouter, Qwen, Moonshot, any OpenAI-compatible endpoint
- 🔍 **Pluggable search** — Serper (Google), Tavily, or DuckDuckGo (no key needed)
- 💾 **Dataset backup** — threads auto-sync to a private HF Dataset; restored on restart
- 🌐 **Cloudflare outbound proxy** — route backend traffic through a Cloudflare Worker (beats HF Spaces IP blocks on some APIs)
- ⏰ **Keep-Awake cron** — Cloudflare Worker pings `/health` on a schedule to prevent cold starts
- 📊 **Live dashboard** — status page at `/` with service health, model, search, backup and keep-awake tiles
- 🔒 **Auth built-in** — DeerFlow v2 JWT auth; create admin at `/setup` on first boot
- ⚡ **Pre-built images** — no source compilation; pulls official GHCR images for sub-5-minute builds
- 📡 **Streaming SSE** — real-time agent output streamed to the browser

---

## Quick Start

### Step 1 — Duplicate this Space

[![Duplicate this Space](https://huggingface.co/datasets/huggingface/badges/resolve/main/duplicate-this-space-xl.svg)](https://huggingface.co/spaces/somratpro/HuggingFlow?duplicate=true)

### Step 2 — Add required secrets

In your new Space → **Settings → Variables and Secrets**, add at minimum:

| Secret | Description |
|--------|-------------|
| `LLM_MODEL` | Model in `provider/model-name` format — e.g. `openai/gpt-4o` |
| `LLM_API_KEY` | API key for the chosen provider |

> [!TIP]
> Add `HF_TOKEN` (a token with write access to your account) to enable thread backup persistence. Without it, all research threads are lost on restart.

### Step 3 — Wait for build

First build pulls pre-built GHCR images — takes ~5 minutes. Subsequent restarts are instant (no rebuild).

### Step 4 — Create your admin account

Visit `https://<your-space>.hf.space/setup` → create username + password.

### Step 5 — Start researching

Open `/workspace` — you're live 🎉

---

## Configuration

### Required Secrets

| Secret | Description |
|--------|-------------|
| `LLM_MODEL` | Model in `provider/model-name` format — see [LLM Providers](#llm-providers) |
| `LLM_API_KEY` | API key for the chosen provider |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SERPER_API_KEY` | — | Google Search via Serper — strongly recommended over DuckDuckGo |
| `TAVILY_API_KEY` | — | Alternative web search (used if Serper not set) |
| `JINA_API_KEY` | — | Better web page fetching via Jina AI |
| `AUTH_JWT_SECRET` | auto-generated | JWT signing secret — set this to keep sessions alive across restarts |
| `HF_TOKEN` | — | Your HF token — enables dataset backup/restore |
| `BACKUP_DATASET_NAME` | `huggingflow-backup` | HF dataset repo name for backups (created automatically) |
| `CUSTOM_BASE_URL` | — | OpenAI-compatible API base URL for any custom/self-hosted provider |
| `SYNC_INTERVAL` | `600` | Seconds between HF Dataset backup syncs |
| `BACKEND_READY_TIMEOUT` | `120` | Seconds to wait for backend startup |
| `FRONTEND_READY_TIMEOUT` | `120` | Seconds to wait for frontend startup |
| `CLOUDFLARE_WORKERS_TOKEN` | — | Cloudflare API token — enables outbound proxy + keep-awake cron |
| `CLOUDFLARE_PROXY_URL` | — | Existing Cloudflare Worker URL (skip auto-setup) |

---

## LLM Providers

Set `LLM_MODEL` to `provider/model-name`:

| Provider | Example `LLM_MODEL` | Notes |
|----------|---------------------|-------|
| **OpenAI** | `openai/gpt-4o` | Default provider |
| **Anthropic** | `anthropic/claude-sonnet-4-5` | Extended thinking supported |
| **Google Gemini** | `google/gemini-2.5-flash` | Extended thinking supported |
| **DeepSeek** | `deepseek/deepseek-chat` | Extended thinking supported |
| **Groq** | `groq/llama-3.3-70b-versatile` | Fast inference |
| **Mistral** | `mistral/mistral-large-latest` | |
| **xAI / Grok** | `xai/grok-3-beta` | |
| **OpenRouter** | `openrouter/anthropic/claude-3-5-sonnet` | Access 200+ models |
| **Qwen / Alibaba** | `qwen/qwen-max` | DashScope compatible |
| **Moonshot / Kimi** | `moonshot/moonshot-v1-128k` | |
| **Custom OpenAI-compat** | `openai/your-model` + `CUSTOM_BASE_URL` | Any self-hosted endpoint |

> **Tip:** Models with extended thinking (Anthropic, Gemini, DeepSeek) produce higher-quality research plans but use more tokens.

---

## Search Tools

DeerFlow uses web search as its primary information source. Configure in priority order:

| Tool | Key | Quality | Cost |
|------|-----|---------|------|
| **Serper** | `SERPER_API_KEY` | ⭐⭐⭐ (real Google) | ~$0.001/query |
| **Tavily** | `TAVILY_API_KEY` | ⭐⭐ | free tier available |
| **DuckDuckGo** | none needed | ⭐ | free, rate-limited |

Serper is strongly recommended for research quality. Sign up at [serper.dev](https://serper.dev) — 2,500 free queries/month.

---

## Cloudflare Proxy

HF Spaces shares IPs that some APIs block. The Cloudflare outbound proxy routes backend HTTP requests through a Cloudflare Worker, giving you a clean egress IP.

**Setup:**

1. Get a Cloudflare API token with **Workers Edit** permission
2. Set `CLOUDFLARE_WORKERS_TOKEN` in your Space secrets
3. On next start, `cloudflare-proxy-setup.py` auto-creates the Worker and sets `CLOUDFLARE_PROXY_URL`

Or manually provide `CLOUDFLARE_PROXY_URL` if you have an existing Worker.

---

## Data Backup

By default threads are stored in SQLite inside the container — **lost on restart**.

Enable persistent backup with HF Datasets:

1. Set `HF_TOKEN` to a token with **Write** access to your profile
2. Optionally set `BACKUP_DATASET_NAME` (default: `huggingflow-backup`)
3. The dataset is created automatically (private) on first sync

**What's backed up:** SQLite database (threads, messages, uploads index), workspace files.

**Sync schedule:** every `SYNC_INTERVAL` seconds (default 10 min) + on graceful shutdown + on startup (restore).

---

## Stay Alive (Keep-Awake)

Free HF Spaces pause after ~15 minutes of inactivity. Fix it with a Cloudflare Worker cron:

1. Set `CLOUDFLARE_WORKERS_TOKEN` (same token as proxy setup)
2. `cloudflare-keepalive-setup.py` creates a Worker that pings `/health` every 10 minutes
3. Status shown in the dashboard **Keep Awake** tile

Check `KEEPALIVE_STATUS_FILE` (`/tmp/huggingflow-cloudflare-keepalive-status.json`) for current state.

---

## Architecture

```
Browser
  │
  ▼  :7860
health-server.js  ──── /          → status dashboard (HTML)
  │               ──── /health    → JSON health check
  │               ──── /status    → JSON full status
  │               ──── /*         → proxy to nginx
  │
  ▼  :7861
nginx
  │  /api/langgraph/*  → rewrite → /api/*  → backend :8001
  │  /api/*            →                   → backend :8001
  │  /health           →                   → backend :8001/health
  │  /docs /redoc      →                   → backend :8001
  │  /*                →                   → frontend :3000
  │
  ├─▶ :8001  FastAPI (uvicorn)  — DeerFlow gateway, agents, auth, SQLite
  └─▶ :3000  Next.js            — DeerFlow UI (server-side rendered)
```

**Port map:**

| Port | Service | Exposed |
|------|---------|---------|
| 7860 | health-server.js | ✅ public (HF Spaces) |
| 7861 | nginx | internal only |
| 8001 | FastAPI backend | internal only |
| 3000 | Next.js frontend | internal only |

**Images used:**

- `ghcr.io/bytedance/deer-flow-backend:latest` — pre-built Python backend + `.venv`
- `ghcr.io/bytedance/deer-flow-frontend:latest` — pre-built Next.js + `node_modules`
- No source compilation — build time ~5 min instead of 30+ min

---

## Local Development

```bash
git clone https://github.com/somratpro/HuggingFlow
cd HuggingFlow

# Build
docker build -t huggingflow .

# Run (set your own keys)
docker run -p 7860:7860 \
  -e LLM_MODEL=openai/gpt-4o \
  -e LLM_API_KEY=sk-... \
  -e SERPER_API_KEY=... \
  huggingflow
```

Open `http://localhost:7860` for the dashboard, `http://localhost:7860/setup` to create your admin account, then `http://localhost:7860/workspace`.

**Useful routes:**

| Route | Description |
|-------|-------------|
| `/` | Status dashboard |
| `/workspace` | DeerFlow research UI |
| `/setup` | Admin account creation (first boot only) |
| `/api/health` | Backend health (JSON) |
| `/docs` | Swagger API reference |
| `/redoc` | ReDoc API reference |

---

## Troubleshooting

**"Application error" on `/workspace` or `/setup`**
> The pre-built frontend requires `DEER_FLOW_TRUSTED_ORIGINS` to be set explicitly. `start.sh` handles this automatically. If you see this error in a custom setup, ensure the env var is set before starting Next.js.

**Build takes 30+ minutes / OOMKilled**
> Ensure Docker has ≥4 GB RAM. HuggingFlow uses pre-built images specifically to avoid compilation. If you're rebuilding from source, add `NODE_OPTIONS=--max-old-space-size=3072`.

**DuckDuckGo returning no results**
> DuckDuckGo rate-limits aggressively from shared IPs. Set `SERPER_API_KEY` or `TAVILY_API_KEY`.

**Threads lost after restart**
> Set `HF_TOKEN` and `BACKUP_DATASET_NAME` to enable dataset sync. Without it, storage is ephemeral.

**Space goes to sleep**
> Set `CLOUDFLARE_WORKERS_TOKEN` to enable the keep-awake cron. Alternatively, upgrade to a paid HF Space tier.

**Backend health shows `not_authenticated`**
> Normal — DeerFlow v2 protects all `/api/*` routes. The public health endpoint is `/health` (no auth). nginx routes `/health` → `backend:8001/health`.

---

## More Projects

Similar projects by [@somratpro](https://github.com/somratpro) — all free, one-click deploy on HF Spaces:

| Project | What it runs | HF Space | GitHub |
|---------|-------------|----------|--------|
| **HuggingClip** | Paperclip — AI agent orchestration | [Space](https://huggingface.co/spaces/somratpro/HuggingClip) | [Repo](https://github.com/somratpro/HuggingClip) |
| **HuggingClaw** | OpenClaw — Claude Code in the browser | [Space](https://huggingface.co/spaces/somratpro/HuggingClaw) | [Repo](https://github.com/somratpro/HuggingClaw) |
| **HuggingMes** | Hermes — self-hosted agent gateway | [Space](https://huggingface.co/spaces/somratpro/HuggingMes) | [Repo](https://github.com/somratpro/HuggingMes) |
| **Hugging8n** | n8n — workflow & automation platform | [Space](https://huggingface.co/spaces/somratpro/Hugging8n) | [Repo](https://github.com/somratpro/Hugging8n) |
| **HuggingPost** | Postiz — social media scheduler | [Space](https://huggingface.co/spaces/somratpro/HuggingPost) | [Repo](https://github.com/somratpro/HuggingPost) |

---

## ❤️ Support

If HuggingFlow saves you time, consider buying me a coffee to keep the projects alive!

**USDT (TRC-20 / TRON network only)**

```
TELx8TJz1W1h7n6SgpgGNNGZXpJCEUZrdB
```

> [!WARNING]
> Send **USDT on TRC-20 network only**. Sending other tokens or using a different network will result in permanent loss.

---

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

```
Fork → branch → commit → PR
```

---

## License

MIT — see [LICENSE](LICENSE).

DeerFlow is © ByteDance, licensed under MIT.

---

<div align="center">
  <sub>Built with ❤️ by <a href="https://github.com/somratpro">somratpro</a> · Powered by <a href="https://github.com/bytedance/deer-flow">DeerFlow</a></sub>
</div>

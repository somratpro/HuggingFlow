# 🦌 HuggingDeer

**DeerFlow** research agent running as a self-hosted [Hugging Face Space](https://huggingface.co/spaces) (Docker).

Single-container deployment — frontend (Next.js) + backend (FastAPI) + nginx all in one image. No Docker-in-Docker, no Kubernetes.

## Required Secrets

Set these in **Settings → Variables and Secrets** on your HF Space:

| Secret | Required | Description |
|--------|----------|-------------|
| `LLM_MODEL` | ✅ | Model in `provider/name` format (see below) |
| `LLM_API_KEY` | ✅ | API key for the chosen provider |
| `SERPER_API_KEY` | recommended | Google Search via Serper (better than DuckDuckGo) |
| `TAVILY_API_KEY` | optional | Alternative web search |
| `JINA_API_KEY` | optional | Better web page fetching |
| `AUTH_JWT_SECRET` | optional | JWT signing secret — auto-generated if not set (sessions reset on restart) |
| `HF_TOKEN` | optional | Your HF token — enables dataset backup/restore of threads |
| `BACKUP_DATASET_NAME` | optional | HF dataset repo for backup (default: `huggingdeer-backup`) |

## LLM_MODEL format

```
provider/model-name
```

Examples:

```
openai/gpt-4o
openai/gpt-4o-mini
anthropic/claude-sonnet-4-5
anthropic/claude-opus-4-5
google/gemini-2.5-flash
deepseek/deepseek-chat
deepseek/deepseek-reasoner
openrouter/anthropic/claude-3-5-sonnet
mistral/mistral-large-latest
groq/llama-3.3-70b-versatile
```

## Deploy to HF Spaces

1. Duplicate this repo to your HF account as a **Docker Space**
2. Add required secrets
3. Space builds and starts (~5-10 min on first build)

## Optional env vars

| Variable | Default | Description |
|----------|---------|-------------|
| `CUSTOM_BASE_URL` | — | OpenAI-compatible API base URL (for custom providers) |
| `SYNC_INTERVAL` | `600` | Seconds between HF Dataset backups |
| `BACKEND_READY_TIMEOUT` | `120` | Seconds to wait for backend startup |
| `FRONTEND_READY_TIMEOUT` | `120` | Seconds to wait for frontend startup |
| `SPACE_HOST` | auto | Set by HF Spaces automatically |

## What runs inside

| Process | Port | Role |
|---------|------|------|
| nginx | 7860 | Public reverse proxy (routes `/api/*` → backend, `/*` → frontend) |
| uvicorn (FastAPI) | 8001 | DeerFlow gateway — agents, threads, auth |
| Next.js | 3000 | DeerFlow UI |

## Caveats

- **No Docker sandbox**: DeerFlow's `bash` / code execution tool is disabled by default (`allow_host_bash: false`). File read/write and web search work fine.
- **Ephemeral storage**: container resets on restart. Enable `HF_TOKEN` + `BACKUP_DATASET_NAME` to persist threads.
- **Single worker**: backend runs 2 uvicorn workers. For heavy use, consider a dedicated server.

## Source

DeerFlow: https://github.com/bytedance/deer-flow

# Changelog

All notable changes to HuggingFlow are documented here.

## [1.0.0] - 2026-05-08

### Added

- Initial public release of HuggingFlow
- DeerFlow v2 (ByteDance) deployed as a single-container Hugging Face Space
- Pre-built GHCR image strategy — pulls `ghcr.io/bytedance/deer-flow-backend:latest` and `ghcr.io/bytedance/deer-flow-frontend:latest` instead of compiling from source; build time ~5 min (was 30+ min)
- Multi-provider LLM support: OpenAI, Anthropic, Google Gemini, DeepSeek, Groq, Mistral, xAI/Grok, OpenRouter, Qwen/Alibaba, Moonshot/Kimi, any OpenAI-compatible endpoint
- Pluggable search: Serper (Google), Tavily, DuckDuckGo fallback
- Live status dashboard at `/` — tile grid showing DeerFlow App, Model, Runtime, Search, Backup, Keep Awake; auto-refreshes every 30 s
- HF Dataset backup/restore via `deerflow-sync.py` — syncs SQLite DB + workspace files on interval and graceful shutdown
- Cloudflare outbound proxy — routes backend traffic through a Cloudflare Worker to bypass HF Spaces IP blocks
- Cloudflare keep-awake cron — Worker pings `/health` every 10 min to prevent free-tier sleep
- JWT auth via DeerFlow v2 — admin account created at `/setup` on first boot
- nginx reverse proxy (port 7861) — routes `/api/*` to FastAPI backend, `/*` to Next.js frontend, LangGraph SDK alias at `/api/langgraph/*`
- health-server.js (port 7860, public) — status dashboard + transparent reverse proxy to nginx + WebSocket upgrade passthrough
- Graceful shutdown with final HF Dataset sync
- `docker-compose.yml` for local development
- `.env.example` configuration reference
- MIT License

### Fixed

- `DEER_FLOW_TRUSTED_ORIGINS` must be explicitly set for pre-built frontend image (sha `af6e48cc`); without it, zod schema validation fails silently → "Application error" on every Next.js page
- `--workers 1` on uvicorn prevents SQLite `CREATE TABLE` race condition with multiple workers
- Next.js `.bin/next` is a shell shim — must not be called with `node` prefix
- nginx `alias` on a file path appends `index.html` — replaced with `root` + `try_files`

## [Unreleased]

### Planned

- Multi-user admin management UI
- Backup versioning and restore from specific snapshots
- Prometheus / Grafana monitoring integration
- External PostgreSQL support option
- GitHub Actions CI for image freshness checks
- Kubernetes deployment manifests

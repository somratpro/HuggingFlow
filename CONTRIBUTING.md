# Contributing to HuggingFlow

Thank you for your interest in contributing!

## Bug Reports

1. Check existing [issues](https://github.com/somratpro/HuggingFlow/issues) first
2. Open a new issue with:
   - Clear title and description
   - Steps to reproduce
   - Expected vs actual behavior
   - Your `LLM_MODEL` provider (no keys please)
   - HF Space tier or Docker version if relevant

## Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Make changes and test locally (see below)
4. Commit using [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`
5. Push and open a Pull Request describing what changed and why

Open an issue first for large or architectural changes.

## Local Development

```bash
# Clone
git clone https://github.com/somratpro/HuggingFlow
cd HuggingFlow

# Configure
cp .env.example .env
# Edit .env — set LLM_MODEL, LLM_API_KEY, optionally SERPER_API_KEY

# Build and run
docker-compose up --build

# Dashboard
open http://localhost:7860/

# Create admin account
open http://localhost:7860/setup

# Research workspace
open http://localhost:7860/workspace

# Health check
curl http://localhost:7860/health
```

Hot-reload for orchestration scripts: `docker-compose.yml` volume-mounts `start.sh`, `health-server.js`, `deerflow-sync.py`, and `nginx.conf` — edit and restart the container without a full rebuild.

## File Overview

| File | Purpose |
|------|---------|
| `Dockerfile` | Container build — pulls pre-built DeerFlow GHCR images |
| `start.sh` | Startup orchestration: config generation, service sequencing, graceful shutdown |
| `health-server.js` | Port 7860 public gateway — status dashboard + transparent reverse proxy to nginx |
| `nginx.conf` | nginx reverse proxy (port 7861) — routes API, frontend, LangGraph alias |
| `deerflow-sync.py` | HF Dataset backup/restore for SQLite DB + workspace files |
| `cloudflare-proxy.js` | Node.js `http`/`https` agent that routes traffic through a Cloudflare Worker |
| `cloudflare-proxy-setup.py` | Auto-provisions the Cloudflare outbound proxy Worker |
| `cloudflare-keepalive-setup.py` | Auto-provisions the Cloudflare keep-awake cron Worker |
| `docker-compose.yml` | Local development setup |
| `.env.example` | Full configuration reference with inline documentation |

## Guidelines

- Keep changes minimal and focused — avoid touching unrelated files
- Test with at least one LLM provider before submitting
- Update `README.md` and `.env.example` if you add new environment variables
- Update `CHANGELOG.md` with a summary under `[Unreleased]`
- Security issues: see [SECURITY.md](SECURITY.md) — do not open public issues for vulnerabilities

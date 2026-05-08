# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | ✅ Yes    |

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, report privately:

- Open a [GitHub Security Advisory](https://github.com/somratpro/HuggingFlow/security/advisories/new) (preferred)
- Or email the maintainer directly (see GitHub profile)

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will respond within 48 hours and aim to patch critical issues within 7 days.

## Security Best Practices

### Secrets Management

- **Never commit secrets to git** — use HF Space secrets or environment variables only
- `LLM_API_KEY`: Store as HF Space secret — never in code or Dockerfile `ENV`
- `HF_TOKEN`: Same — HF Space secret only
- `AUTH_JWT_SECRET`: Generate a strong random value (`openssl rand -base64 32`); without it, a new secret is generated on every restart (sessions lost)
- `CLOUDFLARE_WORKERS_TOKEN`: HF Space secret only
- Rotate all tokens immediately if accidentally exposed

### Network Security

- `umask 0077` enforced at startup — all files created owner-only by default
- nginx binds on `127.0.0.1:7861` (internal only) — not exposed externally
- FastAPI backend binds on `127.0.0.1:8001` (internal only)
- Next.js frontend binds on `127.0.0.1:3000` (internal only)
- Only `health-server.js` on port `7860` is publicly accessible

### Container Security

- Non-root user `user` (UID 1000) — required by HF Spaces and a security best practice
- Based on `python:3.12-slim-bookworm` — minimal attack surface
- No secrets baked into the image — all configuration via environment variables
- Cloudflare proxy uses an auto-generated shared secret for Worker authentication

### DeerFlow Auth

- DeerFlow v2 uses JWT auth; all `/api/*` routes require authentication
- Create your admin account at `/setup` immediately after first deploy — it is only accessible until an admin exists
- Set `AUTH_JWT_SECRET` to a strong random value or sessions reset on every restart

### HF Dataset Backup

- Backup dataset is created as **private** automatically
- The archive contains your full SQLite database (threads, messages, API key hashes) — protect your `HF_TOKEN` and dataset access
- Do not share the backup dataset URL publicly

### Cloudflare Worker Proxy

- The Cloudflare Worker proxy can observe proxied HTTP traffic — review the `cloudflare-proxy.js` source before enabling
- The Worker is scoped to specific domains; set `CLOUDFLARE_PROXY_DOMAINS` to restrict further

## Known Limitations

- **HF Spaces free tier is public** — anyone can reach your Space URL. DeerFlow's auth (`/setup` → JWT) protects the API and UI, but the dashboard at `/` and `/health` are intentionally unauthenticated
- **Ephemeral storage without backup** — if `HF_TOKEN` is not set, all threads are lost on restart
- **Single-worker backend** — `uvicorn --workers 1` prevents SQLite race conditions; for high-concurrency workloads, consider a dedicated server with PostgreSQL

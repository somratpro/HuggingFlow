# ════════════════════════════════════════════════════════════════
# HuggingFlow — DeerFlow Research Agent for Hugging Face Spaces
# ════════════════════════════════════════════════════════════════
#
# Single-container deployment of DeerFlow (frontend + backend + nginx)
# Public port 7860 → health-server.js → nginx:7861 → backend:8001 / frontend:3000
#
# Build args:
#   DEER_FLOW_REF  — git ref to clone (branch/tag/sha, default: main)
#   UV_IMAGE       — uv tool image (default: ghcr.io/astral-sh/uv:0.7.20)
#   NODE_MAJOR     — Node.js major version (default: 22)

ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.7.20
ARG DEER_FLOW_REF=main

# ── uv source ────────────────────────────────────────────────────
FROM ${UV_IMAGE} AS uv-source

# ── Stage 1: Clone DeerFlow source ───────────────────────────────
FROM alpine/git:latest AS source
ARG DEER_FLOW_REF
RUN git clone --depth=1 \
    https://github.com/bytedance/deer-flow.git /src && \
    cd /src && \
    git log --oneline -1

# ── Stage 2: Build Next.js frontend ──────────────────────────────
FROM node:22-alpine AS frontend-builder

RUN corepack enable && corepack install -g pnpm@10.26.2

WORKDIR /app
COPY --from=source /src/frontend ./frontend

# pnpm virtual store uses hard links — COPY in later stages works correctly
RUN cd frontend && pnpm install --frozen-lockfile

# SKIP_ENV_VALIDATION=1 bypasses t3-oss env checks (no secrets at build time)
RUN cd frontend && SKIP_ENV_VALIDATION=1 pnpm build

# ── Stage 3: Install Python backend dependencies ──────────────────
FROM python:3.12-slim-bookworm AS backend-builder

COPY --from=uv-source /uv /uvx /usr/local/bin/

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

ENV UV_HTTP_TIMEOUT=120 \
    UV_CONCURRENT_DOWNLOADS=4

WORKDIR /app
COPY --from=source /src/backend ./backend

# Debug + patch markitdown: print every markitdown line found so we can see the exact format,
# then strip [all] extras (speechrecognition 31MB, pdfminer-six 6MB, magika 15MB, onnxruntime 13MB)
RUN python3 - <<'PY'
import pathlib, sys
patched = []
for p in pathlib.Path("/app/backend").rglob("pyproject.toml"):
    t = p.read_text()
    if "markitdown" in t.lower():
        for needle, replacement in [
            ("markitdown[all,xlsx]", "markitdown[xlsx]"),  # keep xlsx, drop all
            ("markitdown[all]",      "markitdown"),         # fallback
        ]:
            if needle in t:
                p.write_text(t.replace(needle, replacement))
                patched.append(f"{p}: {needle!r} -> {replacement!r}")
                break
if patched:
    print("Patched:", patched)
else:
    print("WARNING: no markitdown[all] variant found — heavy extras still included", file=sys.stderr)
PY

# Retry uv sync up to 10x — uv caches downloaded wheels so each retry
# only re-fetches the wheel(s) that failed or timed out previously
RUN cd backend && \
    uv sync || (echo "retry 2"  && uv sync) || (echo "retry 3"  && uv sync) || \
    (echo "retry 4"  && uv sync) || (echo "retry 5"  && uv sync) || \
    (echo "retry 6"  && uv sync) || (echo "retry 7"  && uv sync) || \
    (echo "retry 8"  && uv sync) || (echo "retry 9"  && uv sync) || \
    (echo "retry 10" && uv sync) || \
    (echo "ERROR: uv sync failed after 10 attempts" && exit 1)

# ── Stage 4: Runtime ─────────────────────────────────────────────
FROM python:3.12-slim-bookworm

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONIOENCODING=utf-8 \
    PYTHONUNBUFFERED=1

ARG NODE_MAJOR=22

# Install: Node.js (for health-server + Next.js runtime), nginx (reverse proxy), runtime tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg nginx jq \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] \
       https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
       > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && pip3 install --no-cache-dir --break-system-packages huggingface_hub pyyaml \
    && rm -rf /var/lib/apt/lists/*

# pnpm for `pnpm start` in Next.js runtime
RUN corepack enable && corepack install -g pnpm@10.26.2

# uv for backend startup
COPY --from=uv-source /uv /uvx /usr/local/bin/

# ── Create non-root user UID=1000 (required by HF Spaces) ────────
RUN useradd -m -u 1000 -s /bin/bash user && \
    mkdir -p \
        /app/backend \
        /app/frontend \
        /app/skills \
        /app/data \
        /tmp/nginx-tmp && \
    chown -R 1000:1000 /app /tmp/nginx-tmp && \
    # nginx non-root: redirect all temp/pid/log paths to writable dirs
    chown -R 1000:1000 /var/log/nginx /var/lib/nginx 2>/dev/null || true

# ── Copy built artifacts ──────────────────────────────────────────
# Backend: Python source + pre-built .venv from uv sync
COPY --from=backend-builder --chown=1000:1000 /app/backend /app/backend
# Skills directory (read-only agent skills)
COPY --from=source --chown=1000:1000 /src/skills /app/skills
# Config template (used to generate config.yaml at startup)
COPY --from=source --chown=1000:1000 /src/config.example.yaml /app/config.example.yaml
# Frontend: built .next + node_modules (pnpm hard links — self-contained after COPY)
COPY --from=frontend-builder --chown=1000:1000 /app/frontend /app/frontend

# ── Copy HuggingFlow runtime scripts ─────────────────────────────
COPY --chown=1000:1000 nginx.conf                  /etc/nginx/nginx.conf
COPY --chown=1000:1000 start.sh                    /app/start.sh
COPY --chown=1000:1000 deerflow-sync.py            /app/deerflow-sync.py
COPY --chown=1000:1000 health-server.js            /app/health-server.js
COPY --chown=1000:1000 cloudflare-proxy.js         /app/cloudflare-proxy.js
COPY --chown=1000:1000 cloudflare-proxy-setup.py   /app/cloudflare-proxy-setup.py
COPY --chown=1000:1000 cloudflare-keepalive-setup.py /app/cloudflare-keepalive-setup.py

RUN chmod +x \
    /app/start.sh \
    /app/deerflow-sync.py \
    /app/cloudflare-proxy-setup.py \
    /app/cloudflare-keepalive-setup.py

USER user
WORKDIR /app

EXPOSE 7860

# 120s start period: frontend build + backend uv sync + DB init takes ~60-90s on cold start
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s \
    CMD curl -fsS http://localhost:7860/health || exit 1

CMD ["/app/start.sh"]

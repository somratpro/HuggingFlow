# syntax=docker/dockerfile:1
# ════════════════════════════════════════════════════════════════
# HuggingFlow — DeerFlow Research Agent for Hugging Face Spaces
# ════════════════════════════════════════════════════════════════
#
# Uses official pre-built DeerFlow images from GHCR — no compile step.
# Build time: ~5 min (was 30+ min building from source).
#
# Public port 7860 → health-server.js → nginx:7861 → backend:8001 / frontend:3000
#
# Build args:
#   DEERFLOW_BACKEND  — backend image (default: ghcr.io/bytedance/deer-flow-backend:latest)
#   DEERFLOW_FRONTEND — frontend image (default: ghcr.io/bytedance/deer-flow-frontend:latest)
#   UV_IMAGE          — uv tool image  (default: ghcr.io/astral-sh/uv:0.7.20)
#   NODE_MAJOR        — Node.js major version (default: 22)

ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.7.20
ARG DEERFLOW_BACKEND=ghcr.io/bytedance/deer-flow-backend:latest
ARG DEERFLOW_FRONTEND=ghcr.io/bytedance/deer-flow-frontend:latest

# ── uv source ────────────────────────────────────────────────────
FROM ${UV_IMAGE} AS uv-source

# ── Pre-built DeerFlow images (no source compilation needed) ──────
# Backend image layout:  /app/backend/ (Python source + .venv)
# Frontend image layout: /app/frontend/ (built .next + node_modules)
FROM ${DEERFLOW_BACKEND} AS backend-src
FROM ${DEERFLOW_FRONTEND} AS frontend-src

# ── Minimal source clone (skills + config only) ───────────────────
# skills/ and config.example.yaml are not bundled in the official images
FROM alpine/git:latest AS source
RUN git clone --depth=1 \
    https://github.com/bytedance/deer-flow.git /src && \
    cd /src && \
    git log --oneline -1

# ── Runtime ───────────────────────────────────────────────────────
FROM python:3.12-slim-bookworm

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONIOENCODING=utf-8 \
    PYTHONUNBUFFERED=1

ARG NODE_MAJOR=22

# Layer 1: nginx + base tools (rarely changes — stays cached)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg nginx openssl \
    && rm -rf /var/lib/apt/lists/*

# Layer 2: Node.js (separate layer — apt network stall doesn't force pip re-run)
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] \
       https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
       > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Layer 3: Python helpers with retries (flaky HF Spaces network)
RUN pip3 install --no-cache-dir --break-system-packages --timeout 120 --retries 5 \
        huggingface_hub pyyaml \
    || (echo "pip retry 2" && pip3 install --no-cache-dir --break-system-packages --timeout 120 --retries 5 huggingface_hub pyyaml) \
    || (echo "pip retry 3" && pip3 install --no-cache-dir --break-system-packages --timeout 120 --retries 5 huggingface_hub pyyaml) \
    || (echo "ERROR: pip install failed after 3 attempts" && exit 1)

# pnpm for `pnpm start` in Next.js runtime
RUN corepack enable && corepack install -g pnpm@10.26.2

# uv for backend startup (`uv run --no-sync uvicorn ...`)
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
    chown -R 1000:1000 /var/log/nginx /var/lib/nginx 2>/dev/null || true

# ── Copy pre-built DeerFlow artifacts ────────────────────────────
# Backend: Python source + pre-built .venv (no uv sync / grpcio compile)
COPY --from=backend-src  --chown=1000:1000 /app/backend  /app/backend
# Frontend: built .next + node_modules (no pnpm install / Next.js build)
COPY --from=frontend-src --chown=1000:1000 /app/frontend /app/frontend
# Skills (not bundled in official images)
COPY --from=source --chown=1000:1000 /src/skills           /app/skills
# Config template
COPY --from=source --chown=1000:1000 /src/config.example.yaml /app/config.example.yaml

# ── Copy HuggingFlow runtime scripts ─────────────────────────────
COPY --chown=1000:1000 nginx.conf                    /etc/nginx/nginx.conf
COPY --chown=1000:1000 start.sh                      /app/start.sh
COPY --chown=1000:1000 deerflow-sync.py              /app/deerflow-sync.py
COPY --chown=1000:1000 health-server.js              /app/health-server.js
COPY --chown=1000:1000 cloudflare-proxy.js           /app/cloudflare-proxy.js
COPY --chown=1000:1000 cloudflare-proxy-setup.py     /app/cloudflare-proxy-setup.py
COPY --chown=1000:1000 cloudflare-keepalive-setup.py /app/cloudflare-keepalive-setup.py

RUN chmod +x \
    /app/start.sh \
    /app/deerflow-sync.py \
    /app/cloudflare-proxy-setup.py \
    /app/cloudflare-keepalive-setup.py

USER user
WORKDIR /app

EXPOSE 7860

# 120s start period — restore + backend + frontend startup can take up to 2 min
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s \
    CMD curl -fsS http://localhost:7860/health || exit 1

CMD ["/app/start.sh"]

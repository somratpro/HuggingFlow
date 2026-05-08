#!/bin/bash
set -euo pipefail
umask 0077

# ════════════════════════════════════════════════════════════════
# HuggingFlow — DeerFlow on Hugging Face Spaces
# ════════════════════════════════════════════════════════════════

APP_DIR="/app"
DATA_DIR="${DEER_FLOW_HOME:-/app/data}"
CONFIG_PATH="${DEER_FLOW_CONFIG_PATH:-$DATA_DIR/config.yaml}"
BACKEND_PORT="${BACKEND_PORT:-8001}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
NGINX_PORT="${NGINX_PORT:-7861}"
PUBLIC_PORT="${PORT:-7860}"
SYNC_INTERVAL="${SYNC_INTERVAL:-600}"
BACKEND_READY_TIMEOUT="${BACKEND_READY_TIMEOUT:-120}"
FRONTEND_READY_TIMEOUT="${FRONTEND_READY_TIMEOUT:-120}"

# Apply defaults before exporting so downstream tools never see empty strings
export BACKUP_DATASET_NAME="${BACKUP_DATASET_NAME:-huggingflow-backup}"
export SYNC_INTERVAL="${SYNC_INTERVAL:-600}"

# Export shell vars so inline Python scripts can read them via os.environ
export DATA_DIR CONFIG_PATH
export DEER_FLOW_HOME="$DATA_DIR"
export DEER_FLOW_CONFIG_PATH="$CONFIG_PATH"
export DEER_FLOW_SKILLS_PATH="/app/skills"
export NGINX_PORT PUBLIC_PORT FRONTEND_PORT BACKEND_PORT

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║        🦌 HuggingFlow — DeerFlow         ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── Required env validation ───────────────────────────────────────
ERRORS=""
if [ -z "${LLM_MODEL:-}" ]; then
  ERRORS="${ERRORS}  - LLM_MODEL is not set (e.g. openai/gpt-4o, anthropic/claude-sonnet-4-5)\n"
fi
if [ -z "${LLM_API_KEY:-}" ]; then
  ERRORS="${ERRORS}  - LLM_API_KEY is not set\n"
fi
if [ -n "$ERRORS" ]; then
  echo "Missing required secrets:"
  printf "%b" "$ERRORS"
  echo ""
  echo "Add them in HF Spaces → Settings → Secrets"
  exit 1
fi

# ── Setup runtime directories ─────────────────────────────────────
mkdir -p \
  "$DATA_DIR" \
  "$DATA_DIR/threads" \
  "$DATA_DIR/uploads" \
  "$DATA_DIR/workspace" \
  "$DATA_DIR/logs" \
  "$DATA_DIR/.secrets" \
  /tmp/nginx-tmp/client \
  /tmp/nginx-tmp/proxy \
  /tmp/nginx-tmp/fastcgi \
  /tmp/nginx-tmp/uwsgi \
  /tmp/nginx-tmp/scgi
chmod 700 "$DATA_DIR/.secrets"

# ── AUTH_JWT_SECRET (generate once, persist across restarts) ──────
# Priority: env var (HF Space secret) > saved file > auto-generate
AUTH_JWT_SECRET_FILE="$DATA_DIR/.secrets/auth-jwt-secret"
if [ -z "${AUTH_JWT_SECRET:-}" ]; then
  if [ -f "$AUTH_JWT_SECRET_FILE" ]; then
    AUTH_JWT_SECRET=$(cat "$AUTH_JWT_SECRET_FILE")
    echo "AUTH_JWT_SECRET loaded from disk."
  else
    AUTH_JWT_SECRET=$(openssl rand -base64 48 2>/dev/null | tr -d '\n' || \
                   python3 -c "import secrets; print(secrets.token_urlsafe(64))")
    printf '%s' "$AUTH_JWT_SECRET" > "$AUTH_JWT_SECRET_FILE"
    chmod 600 "$AUTH_JWT_SECRET_FILE"
    echo "AUTH_JWT_SECRET generated and saved to disk."
  fi
fi
export AUTH_JWT_SECRET

# ── Cloudflare outbound proxy setup ──────────────────────────────
if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ] || [ -n "${CLOUDFLARE_PROXY_URL:-}" ]; then
  echo "Setting up Cloudflare outbound proxy..."
  python3 "$APP_DIR/cloudflare-proxy-setup.py" || echo "Warning: CF proxy setup failed, continuing without it."
fi
# Source proxy env (sets CLOUDFLARE_PROXY_URL for keepalive + Node.js)
# shellcheck disable=SC1091
. /tmp/huggingflow-cloudflare-proxy.env 2>/dev/null || true

# ── Cloudflare keepalive setup ────────────────────────────────────
if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ] || [ -n "${CLOUDFLARE_PROXY_URL:-}" ]; then
  echo "Setting up Cloudflare keepalive..."
  python3 "$APP_DIR/cloudflare-keepalive-setup.py" || echo "Warning: CF keepalive setup failed."
fi

# ── Provider → env var + langchain class mapping ──────────────────
# Parse LLM_MODEL in format "provider/model-name" (e.g. "openai/gpt-4o")
LLM_PROVIDER=$(echo "$LLM_MODEL" | cut -d'/' -f1)
LLM_MODEL_NAME=$(echo "$LLM_MODEL" | cut -d'/' -f2-)

# Resolve provider-specific settings
LANGCHAIN_CLASS="langchain_openai:ChatOpenAI"
API_KEY_FIELD="api_key"
MODEL_BASE_URL=""
SUPPORTS_THINKING="false"

case "$LLM_PROVIDER" in
  anthropic)
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="langchain_anthropic:ChatAnthropic"
    API_KEY_FIELD="api_key"
    SUPPORTS_THINKING="true"
    ;;
  google|gemini)
    export GEMINI_API_KEY="${GEMINI_API_KEY:-$LLM_API_KEY}"
    export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="langchain_google_genai:ChatGoogleGenerativeAI"
    API_KEY_FIELD="gemini_api_key"
    LLM_MODEL_NAME="${LLM_MODEL_NAME:-$LLM_PROVIDER}"
    SUPPORTS_THINKING="true"
    ;;
  deepseek)
    export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="deerflow.models.patched_deepseek:PatchedChatDeepSeek"
    API_KEY_FIELD="api_key"
    MODEL_BASE_URL="https://api.deepseek.com/v1"
    SUPPORTS_THINKING="true"
    ;;
  openrouter)
    export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$LLM_API_KEY}"
    export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="langchain_openai:ChatOpenAI"
    API_KEY_FIELD="api_key"
    MODEL_BASE_URL="https://openrouter.ai/api/v1"
    # OpenRouter model names include provider prefix (e.g. anthropic/claude-3-5-sonnet)
    LLM_MODEL_NAME="$LLM_MODEL"
    ;;
  qwen|dashscope|alibaba)
    export DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="langchain_openai:ChatOpenAI"
    API_KEY_FIELD="api_key"
    MODEL_BASE_URL="https://dashscope.aliyuncs.com/compatible-mode/v1"
    ;;
  moonshot|kimi)
    export MOONSHOT_API_KEY="${MOONSHOT_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="langchain_openai:ChatOpenAI"
    API_KEY_FIELD="api_key"
    MODEL_BASE_URL="https://api.moonshot.cn/v1"
    ;;
  mistral)
    export MISTRAL_API_KEY="${MISTRAL_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="langchain_openai:ChatOpenAI"
    API_KEY_FIELD="api_key"
    MODEL_BASE_URL="https://api.mistral.ai/v1"
    ;;
  xai|grok)
    export XAI_API_KEY="${XAI_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="langchain_openai:ChatOpenAI"
    API_KEY_FIELD="api_key"
    MODEL_BASE_URL="https://api.x.ai/v1"
    ;;
  groq)
    export GROQ_API_KEY="${GROQ_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="langchain_openai:ChatOpenAI"
    API_KEY_FIELD="api_key"
    MODEL_BASE_URL="https://api.groq.com/openai/v1"
    ;;
  openai|*)
    export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
    LANGCHAIN_CLASS="langchain_openai:ChatOpenAI"
    API_KEY_FIELD="api_key"
    ;;
esac

# Custom OpenAI-compatible provider override
if [ -n "${CUSTOM_BASE_URL:-}" ]; then
  export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
  LANGCHAIN_CLASS="langchain_openai:ChatOpenAI"
  API_KEY_FIELD="api_key"
  MODEL_BASE_URL="$CUSTOM_BASE_URL"
fi

export LLM_PROVIDER LLM_MODEL_NAME LANGCHAIN_CLASS API_KEY_FIELD MODEL_BASE_URL SUPPORTS_THINKING
export SERPER_API_KEY="${SERPER_API_KEY:-}"
export TAVILY_API_KEY="${TAVILY_API_KEY:-}"
export JINA_API_KEY="${JINA_API_KEY:-}"

# ── Restore from HF Dataset (if configured) ───────────────────────
if [ -n "${HF_TOKEN:-}" ]; then
  echo "Restoring state from HF Dataset..."
  python3 "$APP_DIR/deerflow-sync.py" restore || echo "Warning: restore failed, starting fresh."
else
  echo "HF_TOKEN not set — running without dataset persistence."
fi

# ── Generate config.yaml ──────────────────────────────────────────
echo "Generating config.yaml..."
python3 - <<'PYEOF'
import os, yaml
from pathlib import Path

data_dir = Path(os.environ["DATA_DIR"])
config_path = Path(os.environ["CONFIG_PATH"])

# Load example config as base if no user config exists
if not config_path.exists():
    example = Path("/app/config.example.yaml")
    if example.exists():
        base = yaml.safe_load(example.read_text()) or {}
    else:
        base = {}
else:
    base = yaml.safe_load(config_path.read_text()) or {}

model_name   = os.environ["LLM_MODEL_NAME"]
lc_class     = os.environ["LANGCHAIN_CLASS"]
api_key_field = os.environ["API_KEY_FIELD"]
base_url      = os.environ.get("MODEL_BASE_URL", "")
llm_api_key   = os.environ.get("LLM_API_KEY", "")
thinking      = os.environ.get("SUPPORTS_THINKING", "false").lower() == "true"

# Build model entry
model_entry = {
    "name": model_name,
    "display_name": model_name,
    "use": lc_class,
    "model": model_name,
    api_key_field: llm_api_key,
    "request_timeout": 600.0,
    "max_retries": 2,
    "max_tokens": 8192,
}
if base_url:
    model_entry["base_url"] = base_url
if thinking:
    model_entry["supports_thinking"] = True

# Override models section with our single configured model
base["models"] = [model_entry]

# Sandbox: local (no Docker on HF Spaces)
base.setdefault("sandbox", {})
base["sandbox"]["use"] = "deerflow.sandbox.local:LocalSandboxProvider"
base["sandbox"]["allow_host_bash"] = False

# Search tools: prefer Serper > Tavily > DuckDuckGo (default)
serper_key  = os.environ.get("SERPER_API_KEY", "")
tavily_key  = os.environ.get("TAVILY_API_KEY", "")

if serper_key:
    web_search_tool = {
        "name": "web_search", "group": "web",
        "use": "deerflow.community.serper.tools:web_search_tool",
        "max_results": 5, "api_key": serper_key,
    }
elif tavily_key:
    web_search_tool = {
        "name": "web_search", "group": "web",
        "use": "deerflow.community.tavily.tools:web_search_tool",
        "max_results": 5, "api_key": tavily_key,
    }
else:
    web_search_tool = {
        "name": "web_search", "group": "web",
        "use": "deerflow.community.ddg_search.tools:web_search_tool",
        "max_results": 5,
    }

# Preserve existing tool list, replacing web_search entry
existing_tools = base.get("tools", [])
other_tools = [t for t in existing_tools if t.get("name") != "web_search"]
base["tools"] = [web_search_tool] + other_tools

# Jina AI web_fetch (no key needed for basic usage)
jina_key = os.environ.get("JINA_API_KEY", "")
has_web_fetch = any(t.get("name") == "web_fetch" for t in base["tools"])
if not has_web_fetch:
    web_fetch_entry = {
        "name": "web_fetch", "group": "web",
        "use": "deerflow.community.jina_ai.tools:web_fetch_tool",
        "timeout": 15,
    }
    if jina_key:
        web_fetch_entry["api_key"] = jina_key
    base["tools"].append(web_fetch_entry)

# Persistence: SQLite in data dir
base.setdefault("database", {})
base["database"].setdefault("backend", "sqlite")
# Database file lives in DATA_DIR (persisted via HF Dataset sync)
db_path = str(data_dir / "deerflow.db")
base["database"].setdefault("url", f"sqlite+aiosqlite:///{db_path}")

# Skills path
base.setdefault("skills", {})
base["skills"]["path"] = "/app/skills"

# Enable custom agent management API (allows creating/editing agents in the UI)
base.setdefault("agents_api", {})
base["agents_api"]["enabled"] = True

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(yaml.safe_dump(base, sort_keys=False, allow_unicode=True))
config_path.chmod(0o600)
print(f"Config written to {config_path}")
PYEOF

# ── CORS origins env for backend ─────────────────────────────────
SPACE_HOST="${SPACE_HOST:-}"
if [ -n "$SPACE_HOST" ]; then
  export CORS_ORIGINS="${CORS_ORIGINS:-http://localhost:3000,http://localhost:7860,https://$SPACE_HOST}"
else
  export CORS_ORIGINS="${CORS_ORIGINS:-http://localhost:3000,http://localhost:7860}"
fi

# ── Startup summary ───────────────────────────────────────────────
echo ""
echo "Model     : $LLM_MODEL"
echo "Provider  : $LLM_PROVIDER"
echo "Data dir  : $DATA_DIR"
if [ -n "${SERPER_API_KEY:-}" ]; then
  echo "Search    : Serper (Google)"
elif [ -n "${TAVILY_API_KEY:-}" ]; then
  echo "Search    : Tavily"
else
  echo "Search    : DuckDuckGo (no API key)"
fi
if [ -n "${HF_TOKEN:-}" ]; then
  echo "Backup    : ${BACKUP_DATASET_NAME:-huggingflow-backup} (every ${SYNC_INTERVAL}s)"
else
  echo "Backup    : disabled"
fi
if [ -n "${CLOUDFLARE_PROXY_URL:-}" ]; then
  echo "CF Proxy  : $CLOUDFLARE_PROXY_URL"
fi
if [ -n "$SPACE_HOST" ]; then
  echo "URL       : https://$SPACE_HOST"
fi
echo ""

# ── Graceful shutdown ─────────────────────────────────────────────
graceful_shutdown() {
  echo "Shutting down HuggingFlow..."
  if [ -n "${HF_TOKEN:-}" ]; then
    echo "Saving state to HF Dataset..."
    python3 "$APP_DIR/deerflow-sync.py" sync-once || echo "Warning: shutdown sync failed."
  fi
  nginx -s quit 2>/dev/null || true
  # Kill tracked PIDs explicitly — more reliable than $(jobs -p) in bash
  for pid in "${FRONTEND_PID:-}" "${HEALTH_PID:-}" "${BACKEND_PID:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  sleep 3
  exit 0
}
trap graceful_shutdown SIGTERM SIGINT

# ── Truncate logs on startup (prevent unbounded growth) ──────────
for _log in health-server backend frontend; do
  : > "$DATA_DIR/logs/$_log.log" 2>/dev/null || true
done

# ── Start health-server (public port 7860) ────────────────────────
echo "Starting health-server on port $PUBLIC_PORT..."
node "$APP_DIR/health-server.js" 2>&1 | tee -a "$DATA_DIR/logs/health-server.log" &
HEALTH_PID=$!

# ── Start nginx (internal port 7861) ─────────────────────────────
echo "Starting nginx on port $NGINX_PORT..."
nginx -t 2>/dev/null && nginx || {
  echo "nginx config error:"
  nginx -t
  exit 1
}

# ── Start backend (uvicorn) ───────────────────────────────────────
echo "Starting DeerFlow backend on port $BACKEND_PORT..."
(
  cd "$APP_DIR/backend" && \
  PYTHONPATH=. \
  uv run --no-sync \
    uvicorn app.gateway.app:app \
      --host 127.0.0.1 \
      --port "$BACKEND_PORT" \
      --workers 1 \
    2>&1 | tee -a "$DATA_DIR/logs/backend.log"
) &
BACKEND_PID=$!

# Wait for backend to be ready
echo "Waiting for backend..."
ready=false
for ((i=0; i<BACKEND_READY_TIMEOUT; i++)); do
  if (echo > "/dev/tcp/127.0.0.1/$BACKEND_PORT") 2>/dev/null; then
    ready=true
    break
  fi
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    echo "Backend process died. Last 30 log lines:"
    echo "────────────────────────────────────────"
    tail -30 "$DATA_DIR/logs/backend.log" || true
    exit 1
  fi
  sleep 1
done
if [ "$ready" != "true" ]; then
  echo "Backend failed to start within ${BACKEND_READY_TIMEOUT}s. Last 30 log lines:"
  tail -30 "$DATA_DIR/logs/backend.log" || true
  exit 1
fi
echo "Backend ready."

# ── Build DEER_FLOW_TRUSTED_ORIGINS ───────────────────────────────
# Required in production mode by the pre-built frontend image (af6e48cc):
# gateway-config.ts has NO defaults in prod — both vars must be explicit
# or zod schema fails → config_error → "Application error" on every page.
TRUSTED_ORIGINS="http://localhost:3000,http://localhost:7860"
if [ -n "${SPACE_HOST:-}" ]; then
  TRUSTED_ORIGINS="$TRUSTED_ORIGINS,https://$SPACE_HOST"
fi

# ── Start frontend (Next.js) ──────────────────────────────────────
echo "Starting Next.js frontend on port $FRONTEND_PORT..."
(
  cd "$APP_DIR/frontend" && \
  DEER_FLOW_INTERNAL_GATEWAY_BASE_URL="http://127.0.0.1:$BACKEND_PORT" \
  DEER_FLOW_TRUSTED_ORIGINS="$TRUSTED_ORIGINS" \
  PORT="$FRONTEND_PORT" \
  NODE_OPTIONS="--require $APP_DIR/cloudflare-proxy.js" \
  node_modules/.bin/next start -p "$FRONTEND_PORT" \
    2>&1 | tee -a "$DATA_DIR/logs/frontend.log"
) &
FRONTEND_PID=$!

# Wait for frontend
echo "Waiting for frontend..."
ready=false
for ((i=0; i<FRONTEND_READY_TIMEOUT; i++)); do
  if (echo > "/dev/tcp/127.0.0.1/$FRONTEND_PORT") 2>/dev/null; then
    ready=true
    break
  fi
  if ! kill -0 "$FRONTEND_PID" 2>/dev/null; then
    echo "Frontend process died. Last 30 log lines:"
    echo "────────────────────────────────────────"
    tail -30 "$DATA_DIR/logs/frontend.log" || true
    exit 1
  fi
  sleep 1
done
if [ "$ready" != "true" ]; then
  echo "Frontend failed to start within ${FRONTEND_READY_TIMEOUT}s. Last 30 log lines:"
  tail -30 "$DATA_DIR/logs/frontend.log" || true
  exit 1
fi
echo "Frontend ready."
echo ""
echo "HuggingFlow is up ✓  →  http://localhost:$PUBLIC_PORT"
echo ""

# ── Periodic HF Dataset sync ──────────────────────────────────────
if [ -n "${HF_TOKEN:-}" ]; then
  (
    while true; do
      sleep "$SYNC_INTERVAL"
      python3 "$APP_DIR/deerflow-sync.py" sync-once 2>/dev/null || true
    done
  ) &
fi

# ── Wait for backend (primary process) ───────────────────────────
wait "$BACKEND_PID"

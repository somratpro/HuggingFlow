// HuggingFlow — status dashboard + reverse proxy to nginx (DeerFlow)
// Public port 7860 → nginx:7861
"use strict";
const http = require("http");
const net  = require("net");
const fs   = require("fs");

const PUBLIC_PORT    = parseInt(process.env.PORT || "7860", 10);
const NGINX_PORT     = parseInt(process.env.NGINX_PORT || "7861", 10);
const NGINX_HOST     = "127.0.0.1";
const FRONTEND_PORT  = parseInt(process.env.FRONTEND_PORT || "3000", 10);
const startTime    = Date.now();

// ── Env-derived display values ─────────────────────────────────────────────
const LLM_MODEL     = process.env.LLM_MODEL     || "Not configured";
const HF_TOKEN      = !!process.env.HF_TOKEN;
const SYNC_INTERVAL = process.env.SYNC_INTERVAL || "600";
const SERPER_KEY    = !!process.env.SERPER_API_KEY;
const TAVILY_KEY    = !!process.env.TAVILY_API_KEY;
const SEARCH_LABEL  = SERPER_KEY ? "Serper (Google)" : TAVILY_KEY ? "Tavily" : "DuckDuckGo";

const SYNC_STATUS_FILE      = "/tmp/huggingflow-sync-status.json";
const KEEPALIVE_STATUS_FILE = "/tmp/huggingflow-cloudflare-keepalive-status.json";

// ── Helpers ────────────────────────────────────────────────────────────────
function parseUrl(raw) {
  try { return new URL(raw, "http://localhost"); } catch { return new URL("http://localhost/"); }
}

function escapeHtml(v) {
  return String(v)
    .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
}

function formatUptime(ms) {
  const t = Math.floor(ms / 1000);
  const d = Math.floor(t / 86400), h = Math.floor((t % 86400) / 3600), m = Math.floor((t % 3600) / 60);
  if (d) return `${d}d ${h}h ${m}m`;
  if (h) return `${h}h ${m}m`;
  return `${m}m`;
}

function readJson(path) {
  try { return JSON.parse(fs.readFileSync(path, "utf8")); } catch { return null; }
}

function getSyncStatus() {
  const s = readJson(SYNC_STATUS_FILE);
  if (s) return s;
  if (HF_TOKEN) return { status: "configured", message: `Backup enabled. First sync in ${SYNC_INTERVAL}s.` };
  return { status: "disabled", message: "HF_TOKEN not set." };
}

function getKeepaliveStatus() {
  return readJson(KEEPALIVE_STATUS_FILE);
}

function probe(host, port, path, timeout = 1500) {
  return new Promise(resolve => {
    const req = http.get({ hostname: host, port, path, timeout }, res => {
      res.resume();
      resolve(res.statusCode >= 200 && res.statusCode < 400);
    });
    req.on("timeout", () => { req.destroy(); resolve(false); });
    req.on("error",   () => resolve(false));
  });
}

// TCP-only liveness check — confirms port is open without triggering any HTTP/SSR.
// Used for the Next.js frontend probe so we don't hit auth rate-limited endpoints.
function tcpProbe(host, port, timeout = 1500) {
  return new Promise(resolve => {
    const sock = net.connect({ host, port }, () => { sock.destroy(); resolve(true); });
    sock.setTimeout(timeout);
    sock.on("timeout", () => { sock.destroy(); resolve(false); });
    sock.on("error",   () => resolve(false));
  });
}

// ── Dashboard HTML renderer ────────────────────────────────────────────────
function badge(label, tone = "neutral") {
  return `<span class="badge ${tone}">${escapeHtml(label)}</span>`;
}

function tile({ title, value, detail = "", tone = "neutral", meta = "" }) {
  return `<article class="tile ${tone}">
  <div class="tile-head"><span class="tile-title">${escapeHtml(title)}</span><span class="tile-dot"></span></div>
  <div class="tile-value">${value}</div>
  ${detail ? `<div class="tile-detail">${escapeHtml(detail)}</div>` : ""}
  ${meta   ? `<div class="tile-meta">${meta}</div>` : ""}
</article>`;
}

function renderDashboard({ backendUp, frontendUp, uptimeHuman, sync, keepalive }) {
  const appOnline   = backendUp && frontendUp;
  const syncStatus  = String(sync?.status || "unknown");
  const syncTone    = ["success","restored","synced","configured"].includes(syncStatus) ? "ok"
                    : syncStatus === "error"    ? "off"
                    : syncStatus === "disabled" ? "warn" : "neutral";
  const kaOk        = keepalive?.configured === true;
  const kaTone      = kaOk ? "ok" : process.env.CLOUDFLARE_WORKERS_TOKEN ? "warn" : "neutral";
  const kaLabel     = kaOk ? "CF Cron" : (process.env.CLOUDFLARE_WORKERS_TOKEN ? "Pending" : "Off");

  const tiles = [
    tile({
      title: "DeerFlow App",
      value: badge(appOnline ? "Online" : "Starting…", appOnline ? "ok" : "warn"),
      detail: appOnline ? `Backend :8001 · Frontend :3000` : "Services initializing…",
      tone: appOnline ? "ok" : "warn",
    }),
    tile({
      title: "Model",
      value: `<code>${escapeHtml(LLM_MODEL)}</code>`,
      detail: "Configured LLM",
      tone: "neutral",
    }),
    tile({
      title: "Runtime",
      value: escapeHtml(uptimeHuman),
      detail: `Port ${PUBLIC_PORT} · nginx :${NGINX_PORT}`,
      tone: "neutral",
    }),
    tile({
      title: "Search",
      value: badge(SEARCH_LABEL, SERPER_KEY || TAVILY_KEY ? "ok" : "neutral"),
      detail: SERPER_KEY ? "SERPER_API_KEY set"
            : TAVILY_KEY ? "TAVILY_API_KEY set"
            : "No API key — using DuckDuckGo",
      tone: SERPER_KEY || TAVILY_KEY ? "ok" : "neutral",
    }),
    tile({
      title: "Backup",
      value: badge(syncStatus.toUpperCase(), syncTone),
      detail: sync?.message || "No status yet",
      tone: syncTone,
      meta: sync?.timestamp
        ? `<span class="local-time" data-iso="${escapeHtml(sync.timestamp)}"></span>` : "",
    }),
    tile({
      title: "Keep Awake",
      value: badge(kaLabel, kaTone),
      detail: kaOk
        ? `Pings <code>${escapeHtml(keepalive.targetUrl || "/health")}</code> · ${escapeHtml(keepalive.cron || "*/10 * * * *")}`
        : "Set CLOUDFLARE_WORKERS_TOKEN to enable",
      tone: kaTone,
    }),
  ].join("\n");

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <meta http-equiv="refresh" content="30" />
  <title>HuggingFlow Dashboard</title>
  <style>
    :root{color-scheme:dark;--bg:#080c10;--panel:#0e1218;--line:#1e2530;--text:#eef2f7;--muted:#6b7a8d;--soft:#a8b5c4;--good:#22c55e;--warn:#f59e0b;--bad:#f43f5e;--accent:#3b82f6}
    *{box-sizing:border-box}
    body{margin:0;min-height:100vh;font-family:Inter,ui-sans-serif,system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--text);font-size:13px}
    main{width:min(740px,calc(100% - 32px));margin:0 auto;padding:40px 0 48px}
    header{text-align:center;margin-bottom:24px}
    h1{margin:0;font-size:1.7rem;font-weight:900;letter-spacing:-.01em}
    .subtitle{margin-top:10px;color:var(--muted);font-size:.7rem;text-transform:uppercase;letter-spacing:.16em;font-weight:700}
    .hero-action{display:flex;width:100%;min-height:48px;align-items:center;justify-content:center;border-radius:9px;background:var(--accent);color:#fff;text-decoration:none;font-weight:800;font-size:.97rem;margin:22px 0 18px;transition:opacity .15s}
    .hero-action:hover{opacity:.88}
    .hero-action.disabled{background:#1e2530;color:var(--muted);pointer-events:none}
    .grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-bottom:10px}
    .tile{border:1px solid var(--line);background:var(--panel);border-radius:12px;padding:18px;min-height:128px;display:flex;flex-direction:column;gap:10px}
    .tile.ok{border-color:rgba(34,197,94,.22)}
    .tile.warn{border-color:rgba(245,158,11,.24)}
    .tile.off{border-color:rgba(244,63,94,.28)}
    .tile-head{display:flex;align-items:center;justify-content:space-between;gap:10px}
    .tile-title{color:var(--muted);font-size:.65rem;letter-spacing:.18em;text-transform:uppercase;font-weight:800}
    .tile-dot{width:7px;height:7px;border-radius:50%;background:var(--line)}
    .tile.ok .tile-dot{background:var(--good)}
    .tile.warn .tile-dot{background:var(--warn)}
    .tile.off .tile-dot{background:var(--bad)}
    .tile-value{font-size:1.1rem;font-weight:800;overflow-wrap:anywhere}
    .tile-detail{color:var(--soft);line-height:1.45;font-size:.82rem}
    .tile-meta{color:var(--muted);font-size:.74rem;margin-top:auto;overflow-wrap:anywhere}
    code{background:#151c24;border:1px solid #1e2a36;border-radius:5px;padding:2px 6px;color:var(--text);font-size:.88em}
    .badge{display:inline-flex;align-items:center;border:1px solid var(--line);border-radius:999px;padding:5px 11px;font-size:.7rem;font-weight:800;letter-spacing:.04em;text-transform:uppercase}
    .badge.ok{color:var(--good);border-color:rgba(34,197,94,.34);background:rgba(34,197,94,.1)}
    .badge.warn{color:var(--warn);border-color:rgba(245,158,11,.34);background:rgba(245,158,11,.1)}
    .badge.off{color:var(--bad);border-color:rgba(244,63,94,.34);background:rgba(244,63,94,.1)}
    .badge.neutral{color:var(--soft)}
    footer{color:var(--muted);text-align:center;font-size:.73rem;margin-top:20px}
    footer a{color:var(--accent);text-decoration:none}
    @media(max-width:680px){.grid{grid-template-columns:1fr}main{padding-top:28px}}
  </style>
</head>
<body>
<main>
  <header>
    <h1>🦌 HuggingFlow</h1>
    <div class="subtitle">DeerFlow Research Agent · Status Dashboard</div>
  </header>
  <a class="hero-action${appOnline ? "" : " disabled"}" href="/workspace" target="_blank" rel="noopener noreferrer">
    ${appOnline ? "Open DeerFlow Workspace →" : "DeerFlow is starting…"}
  </a>
  <section class="grid">${tiles}</section>
  <footer>Built by <a href="https://github.com/somratpro" target="_blank" rel="noopener noreferrer">@somratpro</a></footer>
</main>
<script>
  document.querySelectorAll('.local-time').forEach(el => {
    const d = new Date(el.getAttribute('data-iso'));
    if (!isNaN(d)) el.textContent = 'Last sync at ' + d.toLocaleTimeString();
  });
</script>
</body>
</html>`;
}

// ── Request handler ────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const url      = parseUrl(req.url || "/");
  const pathname = url.pathname;

  // Health — JSON for HEALTHCHECK and load balancers
  if (pathname === "/health") {
    const [backendUp, frontendUp] = await Promise.all([
      probe(NGINX_HOST, NGINX_PORT, "/health"),
      tcpProbe(NGINX_HOST, FRONTEND_PORT),
    ]);
    const ok = backendUp && frontendUp;
    res.writeHead(ok ? 200 : 503, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({
      status: ok ? "ok" : "degraded",
      backendUp, frontendUp,
      uptime: formatUptime(Date.now() - startTime),
      sync: getSyncStatus(),
      keepalive: getKeepaliveStatus(),
    }));
  }

  // Status — full JSON payload
  if (pathname === "/status") {
    const [backendUp, frontendUp] = await Promise.all([
      probe(NGINX_HOST, NGINX_PORT, "/health"),
      tcpProbe(NGINX_HOST, FRONTEND_PORT),
    ]);
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({
      model: LLM_MODEL,
      search: SEARCH_LABEL,
      uptime: formatUptime(Date.now() - startTime),
      backendUp, frontendUp,
      sync: getSyncStatus(),
      keepalive: getKeepaliveStatus(),
    }));
  }

  // Dashboard — HTML status page (served at / and /dashboard)
  if (pathname === "/" || pathname === "/dashboard") {
    const [backendUp, frontendUp] = await Promise.all([
      probe(NGINX_HOST, NGINX_PORT, "/health"),
      tcpProbe(NGINX_HOST, FRONTEND_PORT),
    ]);
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    return res.end(renderDashboard({
      backendUp, frontendUp,
      uptimeHuman: formatUptime(Date.now() - startTime),
      sync: getSyncStatus(),
      keepalive: getKeepaliveStatus(),
    }));
  }

  // Everything else → proxy to nginx
  const proxyHeaders = {
    ...req.headers,
    host: `${NGINX_HOST}:${NGINX_PORT}`,
    "x-forwarded-for":   req.socket?.remoteAddress || "",
    "x-forwarded-host":  req.headers.host || "",
    "x-forwarded-proto": "https",
  };

  const proxyReq = http.request(
    { hostname: NGINX_HOST, port: NGINX_PORT, path: pathname + url.search, method: req.method, headers: proxyHeaders },
    proxyRes => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
      proxyRes.on("error", () => res.end());
    },
  );

  proxyReq.on("error", err => {
    if (!res.headersSent) {
      res.writeHead(503, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "starting", message: "DeerFlow is initializing…" }));
    } else {
      res.end();
    }
  });

  req.on("error", () => proxyReq.destroy());
  res.on("error", () => proxyReq.destroy());
  req.pipe(proxyReq);
});

// WebSocket upgrade passthrough
server.on("upgrade", (req, socket, head) => {
  const url = parseUrl(req.url || "/");
  const upstream = net.connect(NGINX_PORT, NGINX_HOST, () => {
    upstream.write(
      `${req.method} ${url.pathname}${url.search} HTTP/${req.httpVersion}\r\n` +
      req.rawHeaders.reduce((acc, v, i) => acc + (i % 2 === 0 ? `${v}: ` : `${v}\r\n`), "") +
      "\r\n",
    );
    if (head?.length) upstream.write(head);
    upstream.pipe(socket).pipe(upstream);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error",   () => upstream.destroy());
});

server.timeout          = 0;
server.keepAliveTimeout = 65000;
server.listen(PUBLIC_PORT, "0.0.0.0", () =>
  console.log(`🦌 HuggingFlow health-server :${PUBLIC_PORT} → nginx :${NGINX_PORT}`)
);

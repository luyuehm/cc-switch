#!/usr/bin/env node
'use strict';

/*
 * cpa-failover.js - local runtime failover proxy for CPA endpoints.
 *
 * Claude Code resolves exactly one ANTHROPIC_BASE_URL per session, so a dead
 * primary CPA means a dead session even when CPA_FALLBACK_URLS is configured
 * (that list is only used by cc-sync / cc-test model-list probes).
 *
 * This proxy binds 127.0.0.1:<CPA_FAILOVER_PORT> and forwards every request to
 * the primary endpoint, failing over to CPA_FALLBACK_URLS on transport errors,
 * timeouts, 404, 429 and 5xx. A failed primary is cooled down for
 * CPA_FAILOVER_COOLDOWN_MS, then probed again automatically.
 *
 * Config is read from ~/.claude/cc-switch.env (same file cc-switch uses) with
 * process env taking precedence:
 *   ANTHROPIC_BASE_URL / CPA_PRIMARY_URL / CPA_MODELS_URL   primary
 *   ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY                 key
 *   CPA_FALLBACK_URLS                                        backup list (";" or ",")
 *   CPA_FALLBACK_API_KEY                                     shared backup key
 *
 * Control endpoints (localhost only):
 *   GET  /__failover/health   -> 200 {"ok":true}
 *   GET  /__failover/status   -> JSON state (keys are never exposed)
 *   POST /__failover/reset    -> clear cooldowns
 */

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { URL } = require('url');

// Node 24 honours NODE_USE_ENV_PROXY / HTTP(S)_PROXY for http.request, which would
// send tailnet backup addresses through the local Clash proxy and turn a healthy
// backup into "502 Bad Gateway". A failover hop must always connect directly.
for (const name of ['NODE_USE_ENV_PROXY', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy']) {
  delete process.env[name];
}
const directHttpAgent = new http.Agent({ keepAlive: true });
const directHttpsAgent = new https.Agent({ keepAlive: true });

const HOME = process.env.USERPROFILE || os.homedir();
const CLAUDE_DIR = path.join(HOME, '.claude');
const ENV_FILE = process.env.CPA_FAILOVER_ENV || path.join(CLAUDE_DIR, 'cc-switch.env');
const LOG_FILE = process.env.CPA_FAILOVER_LOG || path.join(CLAUDE_DIR, 'logs', 'cpa-failover.log');
const PID_FILE = process.env.CPA_FAILOVER_PID || path.join(CLAUDE_DIR, 'cpa-failover.pid');

const PORT = parseInt(process.env.CPA_FAILOVER_PORT || '18317', 10);
const COOLDOWN_MS = parseInt(process.env.CPA_FAILOVER_COOLDOWN_MS || '30000', 10);
const HEADER_TIMEOUT_MS = parseInt(process.env.CPA_FAILOVER_HEADER_TIMEOUT_MS || '90000', 10);
const IDLE_TIMEOUT_MS = parseInt(process.env.CPA_FAILOVER_IDLE_TIMEOUT_MS || '600000', 10);
const MAX_BODY_BYTES = parseInt(process.env.CPA_FAILOVER_MAX_BODY_BYTES || String(128 * 1024 * 1024), 10);
const LOG_MAX_BYTES = parseInt(process.env.CPA_FAILOVER_LOG_MAX_BYTES || String(5 * 1024 * 1024), 10);

const startedAt = Date.now();
const stats = { requests: 0, failovers: 0, errors: 0, lastFailoverAt: null };
const endpointStates = new Map();

function log(line) {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
    try {
      if (fs.statSync(LOG_FILE).size > LOG_MAX_BYTES) fs.renameSync(LOG_FILE, LOG_FILE + '.1');
    } catch {}
    fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${line}\n`);
  } catch {}
}

function readEnvFile(file) {
  const out = {};
  try {
    const text = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
    for (const rawLine of text.split(/\r?\n/)) {
      if (/^\s*#/.test(rawLine) || !rawLine.trim()) continue;
      const m = rawLine.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
      if (!m) continue;
      let value = m[2].trim();
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      out[m[1]] = value;
    }
  } catch {}
  return out;
}

let configCache = { mtime: -1, endpoints: [] };

function getSetting(fileEnv, name) {
  if (process.env[name] !== undefined) return process.env[name];
  return fileEnv[name];
}

function normalizeEndpoint(address, label, defaultKey) {
  if (!address) return null;
  let raw = String(address).trim();
  let key = '';
  const pipe = raw.indexOf('|');
  if (pipe >= 0) {
    key = raw.slice(pipe + 1).trim();
    raw = raw.slice(0, pipe).trim();
  }
  if (!key) key = defaultKey || '';
  raw = raw.replace(/\/+$/, '');
  raw = raw.replace(/\/v1\/models$/i, '').replace(/\/v1$/i, '');
  raw = raw.replace(/\/+$/, '');
  if (!raw) return null;
  let parsed;
  try { parsed = new URL(raw); } catch { return null; }
  if (!/^https?:$/.test(parsed.protocol)) return null;
  return { label, base: raw, protocol: parsed.protocol, key };
}

function isSelfEndpoint(endpoint) {
  try {
    const parsed = new URL(endpoint.base);
    const host = parsed.hostname.replace(/^\[|\]$/g, '');
    const port = parseInt(parsed.port || (parsed.protocol === 'https:' ? '443' : '80'), 10);
    return (host === '127.0.0.1' || host === 'localhost' || host === '::1') && port === PORT;
  } catch {
    return false;
  }
}

function loadConfig() {
  let mtime = 0;
  try { mtime = fs.statSync(ENV_FILE).mtimeMs; } catch {}
  if (mtime === configCache.mtime && configCache.endpoints.length) return configCache;

  const fileEnv = readEnvFile(ENV_FILE);
  const primaryKey = getSetting(fileEnv, 'ANTHROPIC_AUTH_TOKEN')
    || getSetting(fileEnv, 'ANTHROPIC_API_KEY')
    || getSetting(fileEnv, 'CPA_API_KEY')
    || '';
  const fallbackSpec = getSetting(fileEnv, 'CPA_FALLBACK_URLS') || '';
  const fallbackKey = getSetting(fileEnv, 'CPA_FALLBACK_API_KEY') || primaryKey;

  // Global mode rewrites settings.json to this proxy; keep the pre-install value as
  // the last address candidate so the proxy still knows its real upstream.
  let stateBaseUrl = '';
  try {
    const state = JSON.parse(fs.readFileSync(path.join(CLAUDE_DIR, 'cpa-failover.state.json'), 'utf8'));
    stateBaseUrl = state.settingsBaseUrl || '';
  } catch {}

  const primaryCandidates = [
    process.env.CPA_PRIMARY_URL,
    process.env.ANTHROPIC_BASE_URL,
    fileEnv.CPA_PRIMARY_URL,
    fileEnv.ANTHROPIC_BASE_URL,
    fileEnv.CPA_MODELS_URL,
    stateBaseUrl,
  ];

  const endpoints = [];
  let primary = null;
  for (const candidate of primaryCandidates) {
    const ep = normalizeEndpoint(candidate, 'primary', primaryKey);
    if (!ep) continue;
    if (isSelfEndpoint(ep)) {
      log(`ignoring primary ${ep.base}: it points at this proxy (loop guard)`);
      continue;
    }
    primary = ep;
    break;
  }
  if (primary) endpoints.push(primary);

  let index = 0;
  for (const entry of String(fallbackSpec).split(/[;,]/)) {
    if (!entry || !entry.trim()) continue;
    index += 1;
    const ep = normalizeEndpoint(entry, `fallback-${index}`, fallbackKey);
    if (ep && !isSelfEndpoint(ep)) endpoints.push(ep);
  }

  for (const ep of endpoints) {
    if (!endpointStates.has(ep.base)) {
      endpointStates.set(ep.base, { downUntil: 0, fails: 0, lastError: '', lastOkAt: null });
    }
  }

  configCache = { mtime, endpoints };
  return configCache;
}

function stateOf(endpoint) {
  let state = endpointStates.get(endpoint.base);
  if (!state) {
    state = { downUntil: 0, fails: 0, lastError: '', lastOkAt: null };
    endpointStates.set(endpoint.base, state);
  }
  return state;
}

function orderedEndpoints() {
  const list = loadConfig().endpoints;
  if (!list.length) return [];
  const now = Date.now();
  const alive = list.filter((ep) => stateOf(ep).downUntil <= now);
  if (alive.length) return alive;
  // Everything is cooling down: half-open with the primary so recovery is detected.
  return [list[0]];
}

function maskKey(key) {
  if (!key) return 'missing';
  return `set(${String(key).length})`;
}

function retryableStatus(status) {
  return status === 404 || status === 408 || status === 425 || status === 429 || status >= 500;
}

function filterRequestHeaders(headers, endpoint) {
  const out = {};
  for (const [name, value] of Object.entries(headers)) {
    const lower = name.toLowerCase();
    if (['host', 'connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade', 'te', 'trailer'].includes(lower)) continue;
    out[lower] = value;
  }
  if (endpoint.key) {
    out['authorization'] = `Bearer ${endpoint.key}`;
    if (out['x-api-key'] !== undefined) out['x-api-key'] = endpoint.key;
  }
  return out;
}

function filterResponseHeaders(headers) {
  const out = {};
  for (const [name, value] of Object.entries(headers)) {
    const lower = name.toLowerCase();
    if (['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade', 'te', 'trailer'].includes(lower)) continue;
    out[lower] = value;
  }
  return out;
}

function sendError(res, status, message) {
  if (res.headersSent) { res.destroy(); return; }
  const body = JSON.stringify({
    type: 'error',
    error: { type: status === 429 ? 'rate_limit_error' : 'api_error', message },
  });
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

function forward(req, res, body) {
  const endpoints = orderedEndpoints();
  if (!endpoints.length) {
    stats.errors += 1;
    return sendError(res, 502, 'cpa-failover: no CPA endpoint configured (set ANTHROPIC_BASE_URL in cc-switch.env)');
  }

  const failures = [];
  let cursor = 0;
  let finished = false;

  const next = () => {
    if (finished) return;
    if (cursor >= endpoints.length) {
      finished = true;
      stats.errors += 1;
      log(`${req.method} ${req.url} ALL FAILED: ${failures.join(' | ')}`);
      return sendError(res, 502, `All CPA endpoints failed: ${failures.join(' | ')}`);
    }
    const endpoint = endpoints[cursor++];
    attempt(endpoint, req, res, body, (error) => {
      failures.push(`${endpoint.label}(${endpoint.base}): ${error}`);
      next();
    }, () => { finished = true; });
  };

  next();
}

function attempt(endpoint, req, res, body, onFail, onDone) {
  const target = new URL(endpoint.base + req.url);
  const transport = target.protocol === 'https:' ? https : http;
  const headers = filterRequestHeaders(req.headers, endpoint);
  headers['host'] = target.host;
  headers['content-length'] = String(body.length);
  delete headers['accept-encoding'];

  const state = stateOf(endpoint);
  const started = Date.now();
  let settled = false;

  const fail = (message) => {
    if (settled) return;
    settled = true;
    clearTimeout(headerTimer);
    state.fails += 1;
    state.downUntil = Date.now() + Math.min(COOLDOWN_MS * Math.max(1, state.fails), 5 * 60 * 1000);
    state.lastError = message;
    log(`failover ${req.method} ${req.url} ${endpoint.label} -> ${message} (${Date.now() - started}ms)`);
    onFail(message);
  };

  const upstream = transport.request({
    protocol: target.protocol,
    hostname: target.hostname,
    port: target.port || undefined,
    path: target.pathname + target.search,
    method: req.method,
    headers,
    agent: target.protocol === 'https:' ? directHttpsAgent : directHttpAgent,
  }, (upstreamRes) => {
    if (settled) { upstreamRes.resume(); return; }
    const status = upstreamRes.statusCode || 0;

    if (retryableStatus(status)) {
      settled = true;
      clearTimeout(headerTimer);
      upstreamRes.resume();
      state.fails += 1;
      state.downUntil = Date.now() + Math.min(COOLDOWN_MS * Math.max(1, state.fails), 5 * 60 * 1000);
      state.lastError = `HTTP ${status}`;
      log(`failover ${req.method} ${req.url} ${endpoint.label} -> HTTP ${status} (${Date.now() - started}ms)`);
      return onFail(`HTTP ${status}`);
    }

    settled = true;
    clearTimeout(headerTimer);
    state.fails = 0;
    state.downUntil = 0;
    state.lastOkAt = Date.now();
    if (endpoint.label !== 'primary') {
      stats.failovers += 1;
      stats.lastFailoverAt = new Date().toISOString();
    }

    log(`${req.method} ${req.url} ${endpoint.label} -> ${status} (${Date.now() - started}ms)${endpoint.label !== 'primary' ? ' [backup]' : ''}`);
    res.writeHead(status, filterResponseHeaders(upstreamRes.headers));
    upstreamRes.pipe(res);
    upstreamRes.on('error', () => res.destroy());
    res.on('close', () => { if (!upstreamRes.complete) upstreamRes.destroy(); });
    onDone();
  });

  const headerTimer = setTimeout(() => {
    upstream.destroy(new Error(`no response headers within ${HEADER_TIMEOUT_MS}ms`));
  }, HEADER_TIMEOUT_MS);

  upstream.setTimeout(IDLE_TIMEOUT_MS, () => {
    upstream.destroy(new Error(`upstream idle for ${IDLE_TIMEOUT_MS}ms`));
  });

  upstream.on('error', (error) => {
    if (!res.headersSent) fail(error.message);
    else res.destroy();
  });

  req.on('aborted', () => upstream.destroy());

  if (body.length) upstream.write(body);
  upstream.end();
}

function statusPayload() {
  const config = loadConfig();
  const now = Date.now();
  return {
    ok: true,
    pid: process.pid,
    port: PORT,
    uptimeSec: Math.floor((now - startedAt) / 1000),
    envFile: ENV_FILE,
    cooldownMs: COOLDOWN_MS,
    stats,
    endpoints: config.endpoints.map((ep) => {
      const state = stateOf(ep);
      return {
        label: ep.label,
        base: ep.base,
        key: maskKey(ep.key),
        state: state.downUntil > now ? 'cooling' : 'ready',
        downForSec: state.downUntil > now ? Math.ceil((state.downUntil - now) / 1000) : 0,
        consecutiveFailures: state.fails,
        lastError: state.lastError,
        lastOkAt: state.lastOkAt ? new Date(state.lastOkAt).toISOString() : null,
      };
    }),
  };
}

const server = http.createServer((req, res) => {
  try {
    const pathname = (req.url || '/').split('?')[0];

    if (pathname === '/__failover/health') {
      return sendJson(res, 200, { ok: true, pid: process.pid, port: PORT });
    }
    if (pathname === '/__failover/status') {
      return sendJson(res, 200, statusPayload());
    }
    if (pathname === '/__failover/reset') {
      for (const state of endpointStates.values()) {
        state.downUntil = 0;
        state.fails = 0;
        state.lastError = '';
      }
      log('cooldowns cleared via /__failover/reset');
      return sendJson(res, 200, { ok: true, reset: true });
    }

    stats.requests += 1;
    const chunks = [];
    let size = 0;
    let rejected = false;

    req.on('data', (chunk) => {
      if (rejected) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        rejected = true;
        stats.errors += 1;
        log(`${req.method} ${req.url} rejected: body ${size} > ${MAX_BODY_BYTES} bytes`);
        sendError(res, 413, `Request body exceeds cpa-failover limit (${MAX_BODY_BYTES} bytes)`);
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on('end', () => {
      if (rejected) return;
      forward(req, res, Buffer.concat(chunks));
    });

    req.on('error', () => {
      if (!res.headersSent) sendError(res, 400, 'cpa-failover: client request error');
    });
  } catch (error) {
    stats.errors += 1;
    log(`handler error: ${error && error.stack ? error.stack : error}`);
    sendError(res, 500, 'cpa-failover: internal error');
  }
});

server.on('error', (error) => {
  if (error && error.code === 'EADDRINUSE') {
    log(`port ${PORT} already in use; exiting (another instance is probably running)`);
    process.exit(0);
  }
  log(`server error: ${error && error.message}`);
});

process.on('uncaughtException', (error) => log(`uncaughtException: ${error && error.stack ? error.stack : error}`));
process.on('unhandledRejection', (error) => log(`unhandledRejection: ${error && error.stack ? error.stack : error}`));

function cleanup() {
  try {
    if (fs.existsSync(PID_FILE) && fs.readFileSync(PID_FILE, 'utf8').trim() === String(process.pid)) {
      fs.unlinkSync(PID_FILE);
    }
  } catch {}
}
process.on('SIGINT', () => { cleanup(); process.exit(0); });
process.on('SIGTERM', () => { cleanup(); process.exit(0); });
process.on('exit', cleanup);

server.listen(PORT, '127.0.0.1', () => {
  try { fs.writeFileSync(PID_FILE, String(process.pid)); } catch {}
  const config = loadConfig();
  const list = config.endpoints.map((ep) => `${ep.label}=${ep.base}${ep.key ? '' : ' (no key)'}`).join(', ');
  log(`listening on 127.0.0.1:${PORT}; endpoints: ${list || 'NONE'}`);
});

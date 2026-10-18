// Production server for the demo page: serves the Vite build and proxies /rpc, /rpc/domain
// and /api to the node and the operator service, so the browser only talks to this origin.
import { timingSafeEqual } from "node:crypto";
import { createReadStream, existsSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { proxyTargets } from "./proxy.mjs";

const PORT = Number(process.env.PORT ?? 4173);
const DIST = resolve("dist");
const { rpc, domainRpc, operator } = proxyTargets(process.env);
// Optional access control: DEMO_PASSWORD gates the whole page, assets and proxies included
// (HTTP Basic auth; user name DEMO_USER, default "demo"). /healthz stays open.
const DEMO_USER = process.env.DEMO_USER ?? "demo";
const DEMO_PASSWORD = process.env.DEMO_PASSWORD ?? "";

function sameString(a, b) {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && timingSafeEqual(x, y);
}

function authorized(req) {
  if (!DEMO_PASSWORD) return true;
  const header = req.headers.authorization ?? "";
  if (!header.startsWith("Basic ")) return false;
  const decoded = Buffer.from(header.slice(6), "base64").toString("utf8");
  const colon = decoded.indexOf(":");
  if (colon < 0) return false;
  return sameString(decoded.slice(0, colon), DEMO_USER) && sameString(decoded.slice(colon + 1), DEMO_PASSWORD);
}

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".json": "application/json",
  ".woff2": "font/woff2",
};

function upstreamFor(url) {
  if (url.pathname === "/rpc/domain" || url.pathname.startsWith("/rpc/domain/")) {
    return `${domainRpc}${url.pathname.slice("/rpc/domain".length)}${url.search}`;
  }
  if (url.pathname === "/rpc" || url.pathname.startsWith("/rpc/")) {
    return `${rpc}${url.pathname.slice("/rpc".length)}${url.search}`;
  }
  if (url.pathname.startsWith("/api")) return `${operator}${url.pathname}${url.search}`;
  return null;
}

async function proxy(req, res, target) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const headers = { "content-type": req.headers["content-type"] ?? "application/json", accept: "application/json" };
  const forwarded = req.headers["x-forwarded-for"] ?? req.socket.remoteAddress;
  if (forwarded) headers["x-forwarded-for"] = String(forwarded);
  try {
    const upstream = await fetch(target, {
      method: req.method,
      headers,
      body: req.method === "GET" || req.method === "HEAD" ? undefined : Buffer.concat(chunks),
      signal: AbortSignal.timeout(60_000),
    });
    const body = Buffer.from(await upstream.arrayBuffer());
    res.writeHead(upstream.status, {
      "content-type": upstream.headers.get("content-type") ?? "application/json",
      "cache-control": "no-store",
    });
    res.end(body);
  } catch (error) {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: `upstream unreachable: ${error instanceof Error ? error.message : String(error)}` }));
  }
}

function serveStatic(req, res, url) {
  let path = normalize(join(DIST, decodeURIComponent(url.pathname)));
  if (!path.startsWith(DIST)) {
    res.writeHead(403).end();
    return;
  }
  if (!existsSync(path) || statSync(path).isDirectory()) path = join(DIST, "index.html");
  const type = TYPES[extname(path)] ?? "application/octet-stream";
  const immutable = url.pathname.startsWith("/assets/");
  res.writeHead(200, { "content-type": type, "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-cache" });
  createReadStream(path).pipe(res);
}

createServer((req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (url.pathname === "/healthz") {
    res.writeHead(200, { "content-type": "text/plain" }).end("ok");
    return;
  }
  if (!authorized(req)) {
    res.writeHead(401, { "www-authenticate": 'Basic realm="Private settlement domains demo", charset="UTF-8"', "content-type": "text/plain" });
    res.end("authentication required");
    return;
  }
  const target = upstreamFor(url);
  if (target) return void proxy(req, res, target);
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405).end();
    return;
  }
  serveStatic(req, res, url);
}).listen(PORT, () => {
  // No host: dual-stack (`::`), reachable over IPv4 and IPv6.
  console.log(`demo frontend on :${PORT} (rpc -> ${rpc}, domains -> ${domainRpc}, api -> ${operator}; ${DEMO_PASSWORD ? "password protected" : "open"})`);
});

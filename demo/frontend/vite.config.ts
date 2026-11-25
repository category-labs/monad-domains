import { resolve } from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { proxyTargets } from "./proxy.mjs";

// The page only ever talks to its own origin: /rpc is forwarded to the node's L1 route,
// /rpc/domain/<id> to its domain routes, and /api to the operator service. The RPC URL
// (which carries the node's access token) therefore never reaches the browser, and the
// node needs no CORS headers. The production server (server.mjs) proxies the same paths.
const { rpc, domainRpc, operator } = proxyTargets(process.env);

const proxy = {
  "/rpc/domain": {
    target: domainRpc,
    changeOrigin: true,
    rewrite: (path: string) => path.replace(/^\/rpc\/domain/, ""),
  },
  "/rpc": {
    target: rpc,
    changeOrigin: true,
    rewrite: (path: string) => path.replace(/^\/rpc/, ""),
  },
  "/api": {
    target: operator,
    changeOrigin: true,
  },
} as const;

export default defineConfig({
  plugins: [
    react(),
    {
      // /demo -> /demo/ in dev and preview, as server.mjs does in production.
      name: "demo-trailing-slash",
      configureServer(server) {
        server.middlewares.use((req, res, next) => {
          if (req.url === "/demo" || req.url?.startsWith("/demo?")) {
            res.writeHead(301, { location: req.url.replace("/demo", "/demo/") }).end();
          } else next();
        });
      },
      configurePreviewServer(server) {
        server.middlewares.use((req, res, next) => {
          if (req.url === "/demo" || req.url?.startsWith("/demo?")) {
            res.writeHead(301, { location: req.url.replace("/demo", "/demo/") }).end();
          } else next();
        });
      },
    },
  ],
  // Two pages: the main demo at / and a second frontend at /demo/ (demo/index.html).
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        demo: resolve(__dirname, "demo/index.html"),
      },
    },
  },
  server: { port: 5173, proxy, fs: { allow: ["../.."] } },
  preview: { proxy, allowedHosts: true },
});

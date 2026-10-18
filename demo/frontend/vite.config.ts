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
  plugins: [react()],
  server: { port: 5173, proxy, fs: { allow: ["../.."] } },
  preview: { proxy, allowedHosts: true },
});

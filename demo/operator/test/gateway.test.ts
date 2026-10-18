import assert from "node:assert/strict";
import { test } from "node:test";
import { gatewayUpstream } from "../src/operator.js";

const domains = [
  { chainId: 75679, rpc: "http://node/domain/75679" },
  { chainId: 141215, rpc: "http://node/domain/141215" },
];

test("the rpc gateway maps /rpc to the L1 and /rpc/domain/<id> to a configured domain", () => {
  assert.equal(gatewayUpstream("/rpc", "http://node", domains), "http://node");
  assert.equal(gatewayUpstream("/rpc/", "http://node", domains), "http://node");
  assert.equal(gatewayUpstream("/rpc/domain/75679", "http://node", domains), "http://node/domain/75679");
  assert.equal(gatewayUpstream("/rpc/domain/141215/", "http://node", domains), "http://node/domain/141215");
});

test("the rpc gateway refuses unknown domains and other paths", () => {
  assert.equal(gatewayUpstream("/rpc/domain/1", "http://node", domains), null);
  assert.equal(gatewayUpstream("/rpc/domain/abc", "http://node", domains), null);
  assert.equal(gatewayUpstream("/rpc/eth", "http://node", domains), null);
  assert.equal(gatewayUpstream("/api/status", "http://node", domains), null);
});

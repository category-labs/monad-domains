import assert from "node:assert/strict";
import { test } from "node:test";
import type { Address } from "viem";
import { DomainAccessListMode, resolveDomainAccess } from "../src/setup.js";

const alice: Address = "0x000000000000000000000000000000000000a11c";

test("the spoke starts with open deployment and sending, and closed reads", () => {
  assert.deepEqual(resolveDomainAccess(), {
    deploy: { mode: DomainAccessListMode.Open, members: [] },
    sendTx: { mode: DomainAccessListMode.Open, members: [] },
    readData: { mode: DomainAccessListMode.Closed, members: [] },
  });
});

test("a starting list keeps its members whatever its mode", () => {
  const access = resolveDomainAccess({
    deploy: { mode: DomainAccessListMode.Allowlist, members: [alice] },
    readData: { mode: DomainAccessListMode.Closed, members: [alice] },
  });
  assert.deepEqual(access.deploy, { mode: DomainAccessListMode.Allowlist, members: [alice] });
  assert.deepEqual(access.sendTx, { mode: DomainAccessListMode.Open, members: [] });
  assert.deepEqual(access.readData, { mode: DomainAccessListMode.Closed, members: [alice] });
});

test("a mode the spoke cannot decode is rejected before its creation is signed", () => {
  assert.throws(
    () => resolveDomainAccess({ sendTx: { mode: 3 as DomainAccessListMode } }),
    /access\.sendTx\.mode is invalid/,
  );
});

test("a member that is not an address is rejected", () => {
  assert.throws(
    () => resolveDomainAccess({ deploy: { mode: DomainAccessListMode.Allowlist, members: ["0xa11c" as Address] } }),
    /access\.deploy\.members entries must be addresses/,
  );
});

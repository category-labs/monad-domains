import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { Abi, Hex } from "viem";

/** Repo-root `out/` directory produced by `forge build`. */
const OUT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../../out");

export interface Artifact {
  abi: Abi;
  bytecode: Hex;
}

/**
 * Loads a compiled contract's ABI and creation bytecode from the Foundry artifacts.
 * Run `forge build` at the repo root first. `sourceFile` is the .sol filename, e.g.
 * `DomainHub.sol`, and `contractName` the contract inside it, e.g. `DomainHub`.
 */
export function loadArtifact(sourceFile: string, contractName: string): Artifact {
  const path = resolve(OUT_DIR, sourceFile, `${contractName}.json`);
  const json = JSON.parse(readFileSync(path, "utf8")) as {
    abi: Abi;
    bytecode: { object?: Hex } | Hex;
  };
  const bytecode = (typeof json.bytecode === "string" ? json.bytecode : json.bytecode.object) as Hex | undefined;
  if (!bytecode || !bytecode.startsWith("0x") || bytecode.length <= 2) {
    throw new Error(`artifacts: no creation bytecode at ${path} — run \`forge build\` at the repo root`);
  }
  return { abi: json.abi, bytecode };
}

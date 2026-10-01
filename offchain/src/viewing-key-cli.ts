import { readFileSync, writeFileSync } from "node:fs";
import { generateViewingKeyFiles, viewingPublicKeyFromPem } from "./viewing-key.js";

/**
 * CLI for domain viewing keys.
 *
 *   npm run viewing-key -- generate <key.pem>   # new P-256 key: writes the unencrypted PKCS#8 PEM
 *                                               # (mode 0600) and prints the matching VIEWING_KEY
 *   npm run viewing-key -- public <key.pem>     # prints VIEWING_KEY for an existing public- or
 *                                               # private-key PEM (e.g. one made with openssl)
 *
 * Start the execution client with `--private-domain <chain id> <spoke address> <key.pem>` and give the printed
 * VIEWING_KEY to every sender (offchain .env, the frontend's viewing-keys.json).
 */
function usage(): never {
  console.error("usage: npm run viewing-key -- generate <key.pem> | public <key.pem>");
  process.exit(2);
}

function main() {
  const [command, path] = process.argv.slice(2);
  if (!command || !path) usage();

  switch (command) {
    case "generate": {
      const files = generateViewingKeyFiles();
      writeFileSync(path, files.privateKeyPem, { mode: 0o600, flag: "wx" });
      console.log(`wrote ${path} (unencrypted PKCS#8 P-256 private key; keep it with the domain execution client)`);
      console.log(`  client flag:  --private-domain <chain id> <spoke address> ${path}`);
      console.log(`  VIEWING_KEY=${files.publicKey}`);
      break;
    }
    case "public": {
      console.log(`VIEWING_KEY=${viewingPublicKeyFromPem(readFileSync(path, "utf8"))}`);
      break;
    }
    default:
      usage();
  }
}

try {
  main();
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
}

import { readFileSync, writeFileSync } from "node:fs";
import { generateEncryptionKeyFiles, encryptionPubKeyFromPem } from "./encryption-key.js";

/**
 * CLI for domain encryption keys.
 *
 *   npm run encryption-key -- generate <key.pem>   # new X25519 key: writes the unencrypted PKCS#8 PEM
 *                                                  # (mode 0600) and prints the matching ENCRYPTION_PUB_KEY
 *   npm run encryption-key -- public <key.pem>     # prints ENCRYPTION_PUB_KEY for an existing public- or
 *                                                  # private-key PEM (e.g. one made with openssl)
 *
 * Start the execution client with `monad-domain --domain <chain id> <key.pem>` and give the printed
 * ENCRYPTION_PUB_KEY to every sender (offchain .env, the frontend's viewing-keys.json).
 */
function usage(): never {
  console.error("usage: npm run encryption-key -- generate <key.pem> | public <key.pem>");
  process.exit(2);
}

function main() {
  const [command, path] = process.argv.slice(2);
  if (!command || !path) usage();

  switch (command) {
    case "generate": {
      const files = generateEncryptionKeyFiles();
      writeFileSync(path, files.privateKeyPem, { mode: 0o600, flag: "wx" });
      console.log(`wrote ${path} (unencrypted PKCS#8 X25519 private key; keep it with the domain execution client)`);
      console.log(`  client flag:  monad-domain --domain <chain id> <spoke address> ${path}`);
      console.log(`  ENCRYPTION_PUB_KEY=${files.publicKey}`);
      break;
    }
    case "public": {
      console.log(`ENCRYPTION_PUB_KEY=${encryptionPubKeyFromPem(readFileSync(path, "utf8"))}`);
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

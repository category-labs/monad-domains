import type { Address, Hex } from "viem";
import { sequenceTransaction, type SequenceConfig } from "./sequence.js";

/**
 * CLI wrapper: submits one domain transaction via the hub, reading config from the environment.
 *
 *   L1_RPC_URL=...          \
 *   HUB_ADDRESS=0x...       \
 *   DOMAIN_CHAIN_ID=..   \
 *   SENDER_KEY=0x...        \  # signs the domain tx and submits on the L1
 *   TO=0x...                \  # domain target (omit for a contract creation)
 *   [DATA=0x...]            \  # domain calldata (default 0x)
 *   [VALUE=0]               \  # domain native value in wei (default 0)
 *   [GAS=1000000]           \  # domain gas limit (default 1_000_000)
 *   [TX_NONCE=0]            \  # domain nonce; required unless DOMAIN_RPC_URL is set
 *   [DOMAIN_RPC_URL=...] \  # if set, the domain nonce is fetched from it
 *   [SEQUENCING_FEE=0]      \  # wei forwarded to the operator on the L1
 *   [VIEWING_KEY=0x...]     \  # domain viewing public key; encrypts the domain tx if set
 *     npm run sequence
 */
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`sequence: ${name} is required`);
  return value;
}

function main() {
  const config: SequenceConfig = {
    l1RpcUrl: required("L1_RPC_URL"),
    hub: required("HUB_ADDRESS") as Address,
    domainChainId: BigInt(required("DOMAIN_CHAIN_ID")),
    senderKey: required("SENDER_KEY") as Hex,
  };
  if (process.env.TO) config.to = process.env.TO as Address;
  if (process.env.DATA) config.data = process.env.DATA as Hex;
  if (process.env.VALUE) config.value = BigInt(process.env.VALUE);
  if (process.env.GAS) config.gas = BigInt(process.env.GAS);
  if (process.env.TX_NONCE) config.nonce = Number(process.env.TX_NONCE);
  if (process.env.DOMAIN_RPC_URL) config.domainRpcUrl = process.env.DOMAIN_RPC_URL;
  if (process.env.SEQUENCING_FEE) config.sequencingFee = BigInt(process.env.SEQUENCING_FEE);
  if (process.env.VIEWING_KEY) config.viewingKey = process.env.VIEWING_KEY as Hex;

  return sequenceTransaction(config);
}

main()
  .then((result) => {
    console.log("Sequenced domain transaction:");
    console.log("  L1 tx:        ", result.l1TxHash);
    console.log("  domain tx: ", result.domainTxHash);
    if (result.event) {
      console.log("  event DomainTransactionSequenced fired:");
      console.log("    domainChainId:", result.event.domainChainId.toString());
      console.log("    fee:             ", result.event.fee.toString());
    } else {
      console.log("  WARNING: DomainTransactionSequenced event not found in receipt");
    }
  })
  .catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });

# Monad Domains Protocol

## Overview

A domain is a private execution environment whose transactions are ordered by the Monad L1 but whose contents only the domain's execution clients can read. Every domain transaction is submitted to the L1 as ciphertext, the L1 orders it, and the domain client decrypts and executes it off the L1's critical path.

The core protocol and its actors are as follows:

| Component | Where | Role |
| --- | --- | --- |
| DomainHub | L1, one instance | Registry of domains (validator set, quorum, fee recipient, viewing public key, checkpoint interval), transaction sequencer inbox, store of attested state roots and outbound message anchors, L1 inbox and outbox for messages |
| DomainSpoke | One instance at each domain | Receives L1-origin messages as system transactions, records domain-origin messages by nonce, holds the access-control rules the client enforces |
| Domain execution client | Off-chain, per domain | `monad-domain`, run beside a Monad node. Derives the domain's blocks from hub events in the node's finalized L1 blocks, decrypts payloads with the viewing secret key, executes them into the domain's own state, serves the domain header |
| Validators | Off-chain keys, one per replica | Sign checkpoints: the domain state root at a scheduled L1 height together with the root of the domain-origin messages recorded since the previous checkpoint. The hub advances once a quorum signed the same checkpoint |

![Protocol components: hub, client, spoke, validators](assets/protocol-components.png)

Senders and validators only ever talk to the hub. The client reads the hub to derive every domain block, and validators carry domain headers and message anchors back up.

End to end: a sender encrypts a signed domain transaction to the domain's viewing key and hands the ciphertext to the hub. The domain client sees the sequencing event, decrypts, and executes the transaction in the next domain block. For message passing from domain -> L1, every validator independently signs the next scheduled checkpoint, whose anchor is the Merkle root of the messages recorded since the previous one. Once the hub holds a quorum of signatures anyone can prove a message against the anchor and have the hub execute or forward it. Messages from L1 to a domain need no proof. The hub records them as events and the client injects one system transaction per event.

## Registering a domain

A domain is identified by its chain ID. A domain is created by calling `registerDomain(domainChainId, validators, quorum, feeRecipient, viewingKey, checkpointInterval)` on the hub. Starting a domain should include the following three steps:

1. **Generate the viewing keypair.** An X25519 key (`openssl genpkey -algorithm X25519`). The secret key goes to every execution client that will serve the domain, as an unencrypted PKCS#8 PEM file. The public key is registered on the hub and used by users to encrypt domain transactions.
2. **Configure the execution clients.** Each replica is started with the domain's chain ID, the address its spoke will have, and the key file, plus the hub address as the sequencer contract. Every replica must hold the same secret key to decrypt the ciphertext.
3. **Deploy the spoke inside the domain.** The spoke is a contract in the domain's own state, not on the L1. Its creation transaction is sequenced through the hub like any other domain transaction.

## Transactions and Message passing

Everything that enters a domain is pushed by the protocol from L1 events.

**Sequenced transactions.** A domain transaction is an ordinary EIP-1559 transaction signed with the domain chain ID, with zero value. Its encrypted bytes are passed to `sequenceToDomain` on the hub with a fee, which the hub forwards to the domain's fee recipient. The fee buys `fee / DOMAIN_GAS_PRICE` gas, capped at `DOMAIN_BLOCK_GAS_LIMIT`, and the transaction is kept only if its gas limit is within that. The execution client derives the transactions of each L1 block from the hub's `DomainTransactionSequenced` events in its receipts, decrypts them, and executes the eligible ones as one gasless domain block (see [Deriving domain blocks](#deriving-domain-blocks)). No gas is charged on the domain.

**Fees.** Every sequencing and message call pays its fee in the L1 native token at the hub's fixed `DOMAIN_GAS_PRICE`, which the execution client mirrors. The hub sells at most `DOMAIN_BLOCK_GAS_LIMIT` gas per domain per L1 block, across sequencing and messages; a call that would exceed it reverts.

**L1 to domain messages.** A call to `sendL1Message` on the hub records an event carrying the target, the payload and the fee, which must be at least `minDeliveryFee(payload length)`. The execution client derives one system transaction per event, with the gas the fee bought as its gas limit, and calls `relayL1Message` on the spoke. The spoke forwards all but `DELIVERY_GAS_RESERVE` of that gas to the target, so a target that fails or runs out of gas is still recorded as failed. Anyone can retry a failed message with `retryL1Message` and a higher gas limit.

**Domain to L1 messages.**

1. A domain contract calls `sendDomainMessage(destinationChainId, to, data)` on the spoke. The spoke builds an envelope of source chain, destination chain, sender, target and the payload.
2. A batch is defined by two consecutive checkpoints: the message IDs recorded between them, in nonce order, are the leaves of a merkle tree whose root is the anchor. The tree hashes sorted pairs with keccak256, so proofs verify with OpenZeppelin `MerkleProof`, and promotes an odd node unchanged to the next level; a single message is its own root.
3. Validators sign the anchor together with the state root. Once a quorum signed, the hub records the anchor.
4. Anyone calls `relayDomainMessage(message, anchor, proof)` on the hub to execute the message. A message to another domain is queued there as an L1 to domain message instead, and the caller attaches its delivery fee.

## Checkpoint attestation

Validators attest checkpoints on a schedule. The hub accepts a checkpoint height that is a multiple of the domain's `checkpointInterval`, above the hub's last attested height.

Each validator signs the EIP-712 digest the hub defines, with domain `{name: "MonadDomainHub", version: "1", chainId: l1ChainId, verifyingContract: hub}` and the struct

```
StateTransition(
    uint64  domainChainId,
    uint256 stateNonce,         // the hub's current per-domain transition counter
    uint64  domainBlockNumber,  // the checkpoint's L1 height
    bytes32 newStateRoot,       // domain state root at that height
    bytes32 domainAnchor        // Merkle root of the batch, or zero
)
```

## Encryption

Two kinds of payload are sealed to a domain's viewing key: the transactions sequenced to it, and the messages other domains send it. Derivation is the only place either is opened.

| Payload | Encrypted |
| --- | --- |
| Sequenced transaction | Yes, by its sender, as below |
| L1 to domain message | No: the sending L1 contract runs in public, and the hub authenticates it |
| Domain to L1 message | No: its recipient runs in public |
| Domain to domain message | Yes, whole, caller included, by the source domain's spoke under the destination's key |

A domain to domain message travels as a domain to L1 message and then an L1 to domain one. The hub will authenticate its envelope against the source domain's anchor without reading it and re-emit it as an `EncryptedL1MessageRecorded` event, and the destination's client will open it and deliver it as a system transaction, as it does an `L1MessageRecorded` event. That sealing is not specified yet, so this version of the client does not derive `EncryptedL1MessageRecorded` events, and messages between domains are plaintext until it is. L1 accounts send plaintext messages only: a message recorded by `sendEncryptedL1Message` is never delivered.

**Profile.** A fixed RFC 9180 Base-mode suite, identical on both sides:

| Parameter | Value |
| --- | --- |
| KEM | DHKEM(X25519, HKDF-SHA256) |
| KDF | HKDF-SHA256 |
| AEAD | AES-128-GCM |
| info | empty |
| Associated data | `abi.encode("monad-transaction-encryption-v1", uint64 domainChainId)` |

**Payload.** `rlpTx = enc[32] || ciphertext || tag[16]`, where `enc` is the sender's ephemeral X25519 public key. The sealed plaintext is `0x01 || signed EIP-2718 transaction`; the client checks and strips the frame byte only after the tag verifies. The profile is fixed, so the payload carries no version, scheme or key tag.

**Associated data.** It is never sent: the sender builds it before encrypting and the client rebuilds it from the event's `domainChainId`. The label keeps a transaction ciphertext from opening as anything else sealed to the domain key, and the chain ID keeps it in its domain, and on its network, should two domains share a key. No sender is bound: the payer of `sequenceToDomain` may be a sponsor unknown at encryption time, and the signed transaction already authenticates its sender.

## Deriving domain blocks

Derivation turns one L1 block into at most one block per domain. It is a function of the L1 block, its receipts, the domain's previous block header on the same L1 chain, and the domain's configuration (chain ID, hub, spoke and viewing key); it reads no domain state. Every client holding the key and the same configuration derives byte-identical blocks. A domain's chain ID is 64 bits, and its low 16 bits are the L1 chain ID.

**Block existence.** Domain blocks advance in lock-step with the L1: an L1 block yields a block for a domain exactly when it emits the domain's `DomainRegistered` event (genesis, block 0) or at least one of its `DomainTransactionSequenced` or `L1MessageRecorded` events, whether or not anything survives the rules below. Block numbering therefore depends only on what the hub accepted. Block 0's body holds the registration block's other events of the domain. A client derives a domain only from its registration onward.

**Body.** Sequenced transactions come first, in (L1 transaction index, log index) order, then one system transaction per message, in log order, which is hub nonce order. Each event's fee buys `min(fee / DOMAIN_GAS_PRICE, DOMAIN_BLOCK_GAS_LIMIT)` gas. A sequenced transaction is kept iff:

- the log comes from the hub and its first topic is the domain's chain ID
- the payload opens under the domain key
- the plaintext is a valid EIP-2718 transaction whose chain ID is the domain's
- its sender recovers and is not `SYSTEM_RELAYER`, and no authorization in it recovers to `SYSTEM_RELAYER`
- its gas limit is within the gas its fee bought

A dropped transaction leaves nothing in the block. Stateful failures (bad nonce, revert) are not dropped: they get a status-0 receipt at execution, so the body is fixed by derivation alone.

**System transactions.** Each `L1MessageRecorded` event becomes:

| Field | Value |
| --- | --- |
| type, chain ID | legacy, the domain's chain ID |
| nonce | the hub's message nonce, so derivation needs no domain state; a message whose nonce does not fit in 64 bits is dropped |
| gas price, gas limit | `DOMAIN_GAS_PRICE`, the gas the message's fee bought |
| to, value | the domain's spoke, 0 |
| data | `relayL1Message(sourceChainId, from, to, data, nonce)` |
| signature | the L1 system sender's key, which is public by design, with RFC 6979 nonces, so the sender recovers to `SYSTEM_RELAYER` and every client derives the same bytes |

**Header.** A domain block is a header and its transactions, in order. Only the header is hashed, and its `transactions_root` commits to the transactions, so how a client stores blocks is its own. The header holds only what derivation produces. Like an Ethereum header, it has no chain ID: the domain's comes from the client's configuration. A derived block's id is `keccak256(rlp(header))` of this header, known before execution, as an L1 block's consensus ID is; each block names its parent's, so derived blocks form a chain on their own, on any L1 branch.

| Field | Value |
| --- | --- |
| `parent_id` | the previous domain block's id; zero for genesis |
| `number` | domain height: 0 at genesis, then +1 per block. Not the L1 block number |
| `l1_block_number`, `l1_block_hash` | the L1 block's number and Ethereum block hash, `keccak256(rlp(header))` |
| `timestamp`, `mix_hash`, `slot_number` | copied from the L1 block; `slot_number` (EIP-7843) is present iff the L1 header has it |
| `gas_limit`, `base_fee_per_gas` | `DOMAIN_BLOCK_GAS_LIMIT`, `DOMAIN_GAS_PRICE` |
| `transactions_root` | ordered trie root of the body's transactions |

## Executing domain blocks

A domain block executes against the domain's state after its previous block (empty before genesis), at the L1's EVM revision at its timestamp, and reads nothing from the L1. It follows the L1's rules except:

- **Gasless.** No balance is checked for fees, nothing is deducted or refunded, and no priority fee or beneficiary is paid. Gas is still metered and limited, and receipts carry it.
- **No value.** A transaction with value fails validation: a domain has no native token.
- **Failed validation keeps its place.** A transaction that fails validation (bad nonce, sender with code, value, ...) gets a receipt with status 0, no gas and no logs.
- **Deliveries.** A transaction from `SYSTEM_RELAYER` skips validation and leaves the relayer's nonce alone; the spoke orders deliveries by the hub nonce.
- **No Monad extensions.** No reserve balance checks, no staking or reserve balance precompiles (their addresses are empty accounts), no system calls around the transactions, no withdrawals and no block reward.

The environment comes from the block's header: `CHAINID` is the domain's chain ID; `NUMBER`, `TIMESTAMP`, `PREVRANDAO`, `GASLIMIT`, `BASEFEE` and `SLOTNUM` come from the header; `COINBASE` is 0; `BLOCKHASH(n)` is the hash of domain block `n` for the previous 256 domain blocks.

**Finalized header.** Execution's output is a standard Ethereum header, so Ethereum tooling reads domain blocks unchanged, and the domain block hash is `keccak256(rlp(header))`. It carries the derived header's fields, `parent_hash` (zero for genesis), the domain's `state_root`, `receipts_root`, `logs_bloom` and `gas_used`, a zero beneficiary and 32 zero bytes of extra data. Its fork fields are present iff the revision has them, as for an L1 header, with the values of a block without withdrawals, blobs or requests.

**State.** Each domain has a state trie of its own, laid out like the L1's at the same revision. Genesis state is empty: a sequenced transaction deploys the spoke, and until it has code a delivery is a call to an empty account and does nothing.

**The client.** `monad-domain` (category-labs/monad) serves one domain beside a Monad node. It follows the node's finalized chain, reading its triedb read-only, appends the derived blocks to a block store of its own, and executes them into a triedb of the domain's own. The Monad node stores nothing for domains and never holds a viewing key. A domain block that fails to execute, an internal error rather than a failed transaction, stops `monad-domain` and never the node.

**Access control at execution time.** Before every call frame in a domain, the client makes a synthetic static call to the spoke's `canCall(caller, context, data)` with a 50,000 gas stipend and proceeds only on a canonical ABI true. The spoke forwards the question to the policy contract that the context contract's policy owner named with `setAccessPolicy`, and admits every caller of a contract without one. A policy implements `IDomainAccessPolicy.canCall` and decides from its own storage and the arguments. This is primarily used for RPC read access control.

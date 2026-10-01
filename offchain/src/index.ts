export { setupDomain, type SetupConfig, type SetupResult } from "./setup.js";
export { sequenceTransaction, type SequenceConfig, type SequenceResult } from "./sequence.js";
export { loadArtifact, type Artifact } from "./artifacts.js";
export {
  EncryptionError,
  decryptMessage,
  decryptTransaction,
  encryptMessage,
  encryptTransaction,
  generateViewingKeyPair,
  type ViewingKeyPair,
} from "./encryption.js";
export {
  generateViewingKeyFiles,
  viewingPublicKeyFromPem,
  viewingSecretKeyFromPem,
  viewingSecretKeyToPem,
  type ViewingKeyFiles,
} from "./viewing-key.js";
export { hashMessage, encodeTransfer, decodeTransfer, type Message } from "./message.js";
export { root, getProof, verify } from "./merkle.js";
export {
  ENCRYPTED_L1_MESSAGE_RECORDED_EVENT,
  L1_MESSAGE_RECORDED_EVENT,
  L1_MESSAGE_RELAYED_EVENT,
  DOMAIN_MESSAGE_RECORDED_EVENT,
  DOMAIN_MESSAGE_RELAYED_EVENT,
  fetchEncryptedL1Messages,
  fetchL1Messages,
  fetchDomainMessages,
  proveMessage,
  l1MessageDeliveryStatus,
  domainMessageDeliveryStatus,
  isDomainAnchorRecorded,
  type L1DeliveryStatus,
  type DomainDeliveryStatus,
  type RecordedMessage,
  type MessageProof,
  type UndecryptableMessage,
} from "./prover.js";

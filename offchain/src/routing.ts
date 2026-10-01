import { parseAbiItem, type Address, type PublicClient } from "viem";
import { hashMessage, domainDeliveryEnvelope, type DomainMessage } from "./message.js";
import { l1MessageDeliveryStatus, type L1DeliveryStatus } from "./prover.js";

export const DOMAIN_MESSAGE_ROUTED_EVENT = parseAbiItem(
  "event DomainMessageRouted(bytes32 indexed messageId, uint64 indexed sourceChainId, uint64 indexed destinationChainId, uint256 deliveryNonce)",
);

export type RoutedDeliveryStatus = L1DeliveryStatus;

/** Query execution on the destination's locally configured spoke. Obtain deliveryNonce
 * from DomainMessageRouted. The hub does not store or need that spoke's address.
 */
export async function routedMessageDeliveryStatus(
  client: PublicClient,
  message: DomainMessage,
  destinationSpoke: Address,
  deliveryNonce: bigint,
): Promise<RoutedDeliveryStatus> {
  const envelope = domainDeliveryEnvelope(message, deliveryNonce);
  return l1MessageDeliveryStatus(client, {
    message: envelope, messageHash: hashMessage(envelope), blockNumber: 0n, logIndex: 0,
  }, destinationSpoke);
}

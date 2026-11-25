import type { Address, Hex } from "viem";
import { generatePrivateKey } from "viem/accounts";
import { browserIdentity, type Identity } from "../lib/account";

/** The two companies on the /demo page; each has its own key in this browser. */
export interface Customer {
  id: "left" | "right";
  name: string;
  kind: string;
}

export const ALDER: Customer = { id: "left", name: "Alder & Co.", kind: "Business wallet" };
export const BRIGHTLINE: Customer = { id: "right", name: "Brightline Ltd.", kind: "Business wallet" };
export const CUSTOMERS = [ALDER, BRIGHTLINE];

const keyStorage = (id: Customer["id"]) => `psd.demo.split.${id}.key`;
/** Keys for this visit when storage is unavailable, so both views still share one key. */
const fallback: Partial<Record<Customer["id"], Hex>> = {};

/** The company's key, created on first visit and kept in this browser. */
export function loadKey(id: Customer["id"]): Hex {
  try {
    const stored = localStorage.getItem(keyStorage(id));
    if (stored && /^0x[0-9a-fA-F]{64}$/.test(stored)) return stored as Hex;
    const fresh = generatePrivateKey();
    localStorage.setItem(keyStorage(id), fresh);
    return fresh;
  } catch {
    return (fallback[id] ??= generatePrivateKey());
  }
}

export function identityFor(customer: Customer): Identity {
  return browserIdentity(loadKey(customer.id));
}

/** The company's account address (the same on the L1 and in both domains). */
export function addressOf(customer: Customer): Address {
  return identityFor(customer).domain.address;
}

// Local storage of sealed-order secrets (rate + salt). Without them an order cannot be revealed and loses the
// no-reveal penalty, so we persist BEFORE sending the commit transaction and offer JSON backups.
import { getAddress, isAddress, isHex } from "viem";
import type { Address, Hex } from "viem";
import { commitmentHash } from "./commitment";
import type { Side } from "./commitment";

export type StoredOrder = {
  chainId: number;
  account: Address;
  orderId: string | null; // null until the commit tx is mined
  bookId: number;
  epoch: string; // bigint as decimal string
  side: Side;
  amount: string;
  collateral: string;
  rateBps: number;
  salt: Hex;
  commitment: Hex;
  createdAt: number;
  txHash?: Hex;
};

export type OrderBackup = {
  app: "overnight-desk";
  kind: "order-secrets";
  version: 1;
  exportedAt: string;
  orders: StoredOrder[];
};

const KEY = "overnight-desk:orders:v1";
const listeners = new Set<() => void>();
let cache: StoredOrder[] | null = null;

function safeRead(): StoredOrder[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.map(validate).filter((o): o is StoredOrder => o !== null) : [];
  } catch {
    return [];
  }
}

export function getOrders(): StoredOrder[] {
  if (cache === null) cache = safeRead();
  return cache;
}

const EMPTY: StoredOrder[] = [];
export function getServerOrders(): StoredOrder[] {
  return EMPTY;
}

function write(orders: StoredOrder[]) {
  cache = orders;
  try {
    window.localStorage.setItem(KEY, JSON.stringify(orders));
  } catch {
    // storage full / disabled: the in-memory copy still works for this session; the UI nags for a backup
  }
  listeners.forEach((l) => l());
}

export function subscribe(l: () => void): () => void {
  listeners.add(l);
  const onStorage = (e: StorageEvent) => {
    if (e.key === KEY) {
      cache = safeRead();
      l();
    }
  };
  if (typeof window !== "undefined") window.addEventListener("storage", onStorage);
  return () => {
    listeners.delete(l);
    if (typeof window !== "undefined") window.removeEventListener("storage", onStorage);
  };
}

export function saveOrder(o: StoredOrder) {
  const rest = getOrders().filter((x) => x.commitment.toLowerCase() !== o.commitment.toLowerCase());
  write([...rest, o]);
}

export function attachOrderId(commitment: Hex, orderId: bigint, txHash?: Hex) {
  write(
    getOrders().map((o) =>
      o.commitment.toLowerCase() === commitment.toLowerCase() ? { ...o, orderId: orderId.toString(), txHash } : o,
    ),
  );
}

export function findByCommitment(commitment: Hex): StoredOrder | undefined {
  return getOrders().find((o) => o.commitment.toLowerCase() === commitment.toLowerCase());
}

/** Validate a record and recompute its commitment (rejects tampered or corrupted entries). */
export function validate(x: unknown): StoredOrder | null {
  if (!x || typeof x !== "object") return null;
  const o = x as Record<string, unknown>;
  try {
    if (typeof o.account !== "string" || !isAddress(o.account)) return null;
    if (typeof o.salt !== "string" || !isHex(o.salt) || o.salt.length !== 66) return null;
    if (typeof o.commitment !== "string" || !isHex(o.commitment) || o.commitment.length !== 66) return null;
    if (o.side !== 0 && o.side !== 1) return null;
    const rec: StoredOrder = {
      chainId: Number(o.chainId),
      account: getAddress(o.account),
      orderId: o.orderId === null || o.orderId === undefined ? null : BigInt(String(o.orderId)).toString(),
      bookId: Number(o.bookId),
      epoch: BigInt(String(o.epoch)).toString(),
      side: o.side,
      amount: BigInt(String(o.amount)).toString(),
      collateral: BigInt(String(o.collateral)).toString(),
      rateBps: Number(o.rateBps),
      salt: o.salt as Hex,
      commitment: o.commitment as Hex,
      createdAt: Number(o.createdAt) || 0,
      txHash: typeof o.txHash === "string" && isHex(o.txHash) ? (o.txHash as Hex) : undefined,
    };
    const h = commitmentHash({
      owner: rec.account,
      bookId: rec.bookId,
      epoch: BigInt(rec.epoch),
      side: rec.side,
      amount: BigInt(rec.amount),
      collateral: BigInt(rec.collateral),
      rateBps: rec.rateBps,
      salt: rec.salt,
    });
    if (h.toLowerCase() !== rec.commitment.toLowerCase()) return null;
    return rec;
  } catch {
    return null;
  }
}

export function exportBackup(filter?: { chainId?: number; account?: Address }): OrderBackup {
  const orders = getOrders().filter(
    (o) =>
      (filter?.chainId === undefined || o.chainId === filter.chainId) &&
      (filter?.account === undefined || o.account.toLowerCase() === filter.account.toLowerCase()),
  );
  return { app: "overnight-desk", kind: "order-secrets", version: 1, exportedAt: new Date().toISOString(), orders };
}

/** Merge a backup file. Returns counts of imported and rejected records. */
export function importBackup(json: string): { imported: number; rejected: number } {
  const parsed: unknown = JSON.parse(json);
  const list: unknown[] = Array.isArray(parsed)
    ? parsed
    : parsed && typeof parsed === "object" && Array.isArray((parsed as { orders?: unknown }).orders)
      ? (parsed as { orders: unknown[] }).orders
      : [];
  let imported = 0;
  let rejected = 0;
  const current = [...getOrders()];
  for (const item of list) {
    const v = validate(item);
    if (!v) {
      rejected++;
      continue;
    }
    const idx = current.findIndex((c) => c.commitment.toLowerCase() === v.commitment.toLowerCase());
    if (idx >= 0) {
      current[idx] = { ...current[idx], orderId: current[idx].orderId ?? v.orderId };
    } else {
      current.push(v);
    }
    imported++;
  }
  write(current);
  return { imported, rejected };
}

export function downloadJson(filename: string, data: unknown) {
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1_000);
}

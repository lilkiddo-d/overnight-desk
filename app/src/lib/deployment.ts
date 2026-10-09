import { getAddress, isAddress } from "viem";
import type { Address } from "viem";

export const CONTRACT_KEYS = [
  "MarketClock",
  "TermRegistry",
  "RepoNote",
  "RepoLocker",
  "OracleAdapter",
  "MarginEngine",
  "FeeCollector",
  "ProjectTokenHooks",
  "Liquidator",
  "ComplianceRegistry",
  "NoteMarket",
  "Timelock",
  "AuctionHouse",
] as const;
export type ContractKey = (typeof CONTRACT_KEYS)[number];

export type Deployment = {
  chainId: number;
  deployedAt: number;
  genesis: number;
  deployer: Address;
  guardian: Address;
  treasury: Address;
  stablecoin: Address;
  termCount: number;
  collateral: Record<string, Address>;
} & Record<ContractKey, Address>;

function addr(o: Record<string, unknown>, k: string): Address {
  const v = o[k];
  if (typeof v !== "string" || !isAddress(v)) throw new Error(`deployment file: missing or invalid address "${k}"`);
  return getAddress(v);
}

/** Validate the JSON written by contracts/script/Deploy.s.sol. Throws with a readable message on bad input. */
export function parseDeployment(json: unknown, expectedChainId: number): Deployment {
  if (!json || typeof json !== "object") throw new Error("deployment file is not a JSON object");
  const o = json as Record<string, unknown>;
  const chainId = Number(o.chainId);
  if (chainId !== expectedChainId) {
    throw new Error(`deployment file is for chain ${String(o.chainId)}, expected ${expectedChainId}`);
  }
  let coll: unknown = o.collateral;
  if (typeof coll === "string") {
    try {
      coll = JSON.parse(coll);
    } catch {
      coll = {};
    }
  }
  const collateral: Record<string, Address> = {};
  if (coll && typeof coll === "object") {
    for (const [sym, a] of Object.entries(coll as Record<string, unknown>)) {
      if (typeof a === "string" && isAddress(a)) collateral[sym] = getAddress(a);
    }
  }
  const contracts = Object.fromEntries(CONTRACT_KEYS.map((k) => [k, addr(o, k)])) as Record<ContractKey, Address>;
  return {
    ...contracts,
    chainId,
    deployedAt: Number(o.deployedAt) || 0,
    genesis: Number(o.genesis) || 0,
    deployer: addr(o, "deployer"),
    guardian: addr(o, "guardian"),
    treasury: addr(o, "treasury"),
    stablecoin: addr(o, "stablecoin"),
    termCount: Number(o.termCount) || 0,
    collateral,
  };
}

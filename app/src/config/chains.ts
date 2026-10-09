// Chain definitions for the frontend.
// SOURCE OF TRUTH: /config/chains.ts at the repo root (robinhoodMainnet, localFork). The values below are copied
// from there so the app does not import files outside its own package (Vercel builds only `app/`). Keep in sync.
import { defineChain } from "viem";

const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;

/** Robinhood Chain mainnet (Arbitrum Orbit L2, ETH gas). See /config/chains.ts -> robinhoodMainnet. */
export const robinhoodChain = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc.mainnet.chain.robinhood.com"] },
  },
  blockExplorers: {
    default: {
      name: "Blockscout",
      url: "https://robinhoodchain.blockscout.com",
      apiUrl: "https://robinhoodchain.blockscout.com/api/",
    },
  },
  contracts: {
    multicall3: { address: MULTICALL3, blockCreated: 0 },
  },
});

/** Local anvil fork of mainnet with chain id 31337. See /config/chains.ts -> localFork. */
export const localFork = defineChain({
  id: 31337,
  name: "Local fork (Robinhood Chain)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8571"] },
  },
  contracts: {
    // the fork inherits mainnet state, including the canonical Multicall3 deployment
    multicall3: { address: MULTICALL3, blockCreated: 0 },
  },
  testnet: true,
});

export const KNOWN_CHAINS = [robinhoodChain, localFork] as const;
export type KnownChain = (typeof KNOWN_CHAINS)[number];

export function explorerTxUrl(chainId: number, hash: string): string | null {
  const c = KNOWN_CHAINS.find((k) => k.id === chainId);
  const url = c && "blockExplorers" in c && c.blockExplorers ? c.blockExplorers.default.url : null;
  return url ? `${url}/tx/${hash}` : null;
}

export function explorerAddressUrl(chainId: number, address: string): string | null {
  const c = KNOWN_CHAINS.find((k) => k.id === chainId);
  const url = c && "blockExplorers" in c && c.blockExplorers ? c.blockExplorers.default.url : null;
  return url ? `${url}/address/${address}` : null;
}

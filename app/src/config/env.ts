// Public, build-time environment. NEXT_PUBLIC_* values are inlined by Next.js, so they must be referenced literally.
import { isAddress } from "viem";
import type { Address } from "viem";

const rawChainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID || "4663");

/** Default (and primary) chain for the deployment: 4663 (Robinhood Chain) or 31337 (local fork). */
export const DEFAULT_CHAIN_ID: number = rawChainId === 31337 ? 31337 : 4663;

/** Optional RPC override for the default chain (e.g. an Alchemy/QuickNode URL). */
export const RPC_URL_OVERRIDE: string = (process.env.NEXT_PUBLIC_RPC_URL || "").trim();

/** Optional WalletConnect Cloud project id. Empty => injected wallets only. */
export const WC_PROJECT_ID: string = (process.env.NEXT_PUBLIC_WC_PROJECT_ID || "").trim();

const rawToken = (process.env.NEXT_PUBLIC_PROJECT_TOKEN || "").trim();
/** Project token address. Empty or invalid => all token / staking UI is hidden. */
export const PROJECT_TOKEN: Address | null = rawToken && isAddress(rawToken) ? (rawToken as Address) : null;

/** ISO-3166 alpha-2 country codes to geoblock (comma separated). Empty => no geoblock. */
export const GEOBLOCK_COUNTRIES: string[] = (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES || "")
  .split(",")
  .map((s) => s.trim().toUpperCase())
  .filter((s) => /^[A-Z]{2}$/.test(s));

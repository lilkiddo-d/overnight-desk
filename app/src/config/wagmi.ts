import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import type { WalletList } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  rainbowWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http } from "wagmi";
import type { Chain } from "viem";
import { localFork, robinhoodChain } from "./chains";
import { DEFAULT_CHAIN_ID, RPC_URL_OVERRIDE, WC_PROJECT_ID } from "./env";

/**
 * Supported chains. The default chain comes first. The local fork is only offered when the app is configured
 * for it (NEXT_PUBLIC_CHAIN_ID=31337), so a production build never shows a localhost network.
 */
export const supportedChains: readonly [Chain, ...Chain[]] =
  DEFAULT_CHAIN_ID === 31337 ? [localFork, robinhoodChain] : [robinhoodChain];

export const SUPPORTED_CHAIN_IDS: number[] = supportedChains.map((c) => c.id);

const wallets: WalletList = WC_PROJECT_ID
  ? [
      {
        groupName: "Popular",
        wallets: [injectedWallet, metaMaskWallet, rabbyWallet, coinbaseWallet, rainbowWallet, walletConnectWallet],
      },
    ]
  : [{ groupName: "Browser wallets", wallets: [injectedWallet, rabbyWallet] }];

function makeConnectors() {
  // connectorsForWallets touches window-only APIs for some wallets; build them only in the browser.
  if (typeof window === "undefined") return [];
  return connectorsForWallets(wallets, {
    appName: "Overnight Desk",
    // RainbowKit requires a string; it is only used by WalletConnect-based wallets, which are not listed when empty.
    projectId: WC_PROJECT_ID || "unset",
  });
}

function transportFor(chain: Chain) {
  if (chain.id === DEFAULT_CHAIN_ID && RPC_URL_OVERRIDE) return http(RPC_URL_OVERRIDE, { batch: false });
  return http(chain.rpcUrls.default.http[0]);
}

export const wagmiConfig = createConfig({
  chains: supportedChains,
  connectors: makeConnectors(),
  transports: Object.fromEntries(supportedChains.map((c) => [c.id, transportFor(c)])),
  ssr: true,
  batch: { multicall: { wait: 16 } },
});

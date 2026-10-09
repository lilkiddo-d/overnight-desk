"use client";

import { useAccount, useSwitchChain } from "wagmi";
import { DEFAULT_CHAIN_ID } from "@/config/env";
import { supportedChains, SUPPORTED_CHAIN_IDS } from "@/config/wagmi";

/** Banner shown when the connected wallet is on an unsupported network. */
export function NetworkGuard() {
  const { isConnected, chainId } = useAccount();
  const { switchChain, isPending, error } = useSwitchChain();
  if (!isConnected || chainId === undefined || SUPPORTED_CHAIN_IDS.includes(chainId)) return null;
  const target = supportedChains.find((c) => c.id === DEFAULT_CHAIN_ID) ?? supportedChains[0];
  return (
    <div className="border-b border-amber-500/30 bg-amber-500/10">
      <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-2 px-4 py-2 text-sm text-amber-200">
        <span>
          Your wallet is on an unsupported network (chain {chainId}). Data below is read from {target.name}.
        </span>
        <div className="flex items-center gap-2">
          {error && <span className="text-xs text-red-300">{error.message.split("\n")[0]}</span>}
          <button type="button" className="btn-primary px-3 py-1.5 text-xs" disabled={isPending} onClick={() => switchChain({ chainId: target.id })}>
            {isPending ? "Switching…" : `Switch to ${target.name}`}
          </button>
        </div>
      </div>
    </div>
  );
}

"use client";

import { createContext, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import { useAccount } from "wagmi";
import { DEFAULT_CHAIN_ID } from "@/config/env";
import { SUPPORTED_CHAIN_IDS } from "@/config/wagmi";
import { parseDeployment } from "@/lib/deployment";
import type { Deployment } from "@/lib/deployment";

export type DeploymentState =
  | { status: "loading"; chainId: number }
  | { status: "missing"; chainId: number }
  | { status: "error"; chainId: number; error: string }
  | { status: "ready"; chainId: number; deployment: Deployment };

const Ctx = createContext<DeploymentState>({ status: "loading", chainId: DEFAULT_CHAIN_ID });

/**
 * The chain the app reads from: the wallet's chain when it is supported, otherwise the configured default.
 * (Writes are blocked by the network guard while the wallet is on an unsupported chain.)
 */
export function useAppChainId(): number {
  const { chainId, isConnected } = useAccount();
  if (isConnected && chainId !== undefined && SUPPORTED_CHAIN_IDS.includes(chainId)) return chainId;
  return DEFAULT_CHAIN_ID;
}

export function DeploymentProvider({ children }: { children: ReactNode }) {
  const chainId = useAppChainId();
  const [state, setState] = useState<DeploymentState>({ status: "loading", chainId });

  useEffect(() => {
    let cancelled = false;
    setState({ status: "loading", chainId });
    fetch(`/deployments/${chainId}.json`, { cache: "no-store" })
      .then(async (res) => {
        if (cancelled) return;
        if (res.status === 404) return setState({ status: "missing", chainId });
        if (!res.ok) return setState({ status: "error", chainId, error: `HTTP ${res.status}` });
        const text = await res.text();
        let json: unknown;
        try {
          json = JSON.parse(text);
        } catch {
          // some hosts answer unknown paths with an HTML page instead of a 404
          return setState({ status: "missing", chainId });
        }
        try {
          setState({ status: "ready", chainId, deployment: parseDeployment(json, chainId) });
        } catch (e) {
          setState({ status: "error", chainId, error: e instanceof Error ? e.message : String(e) });
        }
      })
      .catch((e: unknown) => {
        if (!cancelled) setState({ status: "error", chainId, error: e instanceof Error ? e.message : String(e) });
      });
    return () => {
      cancelled = true;
    };
  }, [chainId]);

  const value = useMemo(() => state, [state]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useDeploymentState(): DeploymentState {
  return useContext(Ctx);
}

/** The deployment for the app chain, or undefined while loading / when not deployed. */
export function useDeployment(): Deployment | undefined {
  const s = useContext(Ctx);
  return s.status === "ready" && s.chainId === s.deployment.chainId ? s.deployment : undefined;
}

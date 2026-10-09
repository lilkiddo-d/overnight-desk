"use client";

import type { ReactNode } from "react";
import { KNOWN_CHAINS } from "@/config/chains";
import { useDeploymentState } from "@/providers/DeploymentProvider";
import { Spinner } from "./ui";

/** Renders children only when the protocol is deployed on the app chain; otherwise a clear status message. */
export function DeploymentGate({ children }: { children: ReactNode }) {
  const s = useDeploymentState();
  const name = KNOWN_CHAINS.find((c) => c.id === s.chainId)?.name ?? `chain ${s.chainId}`;
  if (s.status === "loading") {
    return (
      <div className="card flex items-center gap-2 text-sm text-muted">
        <Spinner /> Loading deployment for {name}…
      </div>
    );
  }
  if (s.status === "missing") {
    return (
      <div className="card text-center">
        <h2 className="text-lg font-semibold">Overnight Desk is not deployed on this network yet</h2>
        <p className="mt-2 text-sm text-muted">
          No deployment file was found for {name} (chain id {s.chainId}). If you run your own instance, deploy the
          contracts and publish <code className="font-mono">/deployments/{s.chainId}.json</code>, or switch to a
          supported network.
        </p>
      </div>
    );
  }
  if (s.status === "error") {
    return (
      <div className="card">
        <h2 className="text-lg font-semibold">Could not load the deployment for {name}</h2>
        <p className="mt-2 break-words text-sm text-bad">{s.error}</p>
      </div>
    );
  }
  return <>{children}</>;
}

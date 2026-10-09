"use client";

import { useReadContract } from "wagmi";
import type { Address } from "viem";
import { ProjectTokenHooksAbi } from "@/abi";
import { PROJECT_TOKEN } from "@/config/env";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

/** Staking UI is shown only when NEXT_PUBLIC_PROJECT_TOKEN is set AND ProjectTokenHooks.isActive() is true. */
export function useStakingEnabled(): boolean {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { data } = useReadContract({
    address: d?.ProjectTokenHooks as Address,
    abi: ProjectTokenHooksAbi,
    functionName: "isActive",
    chainId,
    query: { enabled: !!PROJECT_TOKEN && !!d, staleTime: 60_000 },
  });
  return !!PROJECT_TOKEN && data === true;
}

"use client";

import { useAccount, useReadContract } from "wagmi";
import type { Address } from "viem";
import { ERC20Abi } from "@/abi";
import { useAppChainId } from "@/providers/DeploymentProvider";

export function useTokenBalance(token: Address | undefined): bigint | undefined {
  const chainId = useAppChainId();
  const { address } = useAccount();
  const { data } = useReadContract({
    address: token,
    abi: ERC20Abi,
    functionName: "balanceOf",
    args: [address as Address],
    chainId,
    query: { enabled: !!token && !!address, refetchInterval: 15_000 },
  });
  return data;
}

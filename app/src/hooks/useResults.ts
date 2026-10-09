"use client";

import { useMemo } from "react";
import { useReadContracts } from "wagmi";
import type { Address } from "viem";
import { AuctionHouseAbi } from "@/abi";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";
import type { BookInfo } from "./useProtocol";

export type AuctionResult = {
  bookId: number;
  epoch: bigint;
  cleared: boolean;
  clearingRateBps: number;
  clearedAt: bigint;
  volume: bigint;
  seriesId: bigint;
};

/** AuctionHouse.getResult for every book over the latest `depth` epochs (current epoch included). */
export function useRecentResults(books: BookInfo[], currentEpoch: bigint | undefined, depth = 10) {
  const chainId = useAppChainId();
  const d = useDeployment();
  const epochs = useMemo(() => {
    if (currentEpoch === undefined) return [] as bigint[];
    const out: bigint[] = [];
    for (let i = 0n; i < BigInt(depth) && currentEpoch - i >= 0n; i++) out.push(currentEpoch - i);
    return out;
  }, [currentEpoch, depth]);
  const keys = useMemo(() => books.flatMap((b) => epochs.map((e) => ({ bookId: b.id, epoch: e }))), [books, epochs]);
  const { data, isLoading } = useReadContracts({
    contracts: keys.map(
      (k) =>
        ({
          address: d?.AuctionHouse as Address,
          abi: AuctionHouseAbi,
          functionName: "getResult",
          args: [k.bookId, k.epoch],
          chainId,
        }) as const,
    ),
    query: { enabled: !!d && keys.length > 0, refetchInterval: 20_000 },
  });
  const results = useMemo<AuctionResult[]>(
    () =>
      keys.flatMap((k, i) => {
        const r = data?.[i];
        if (r?.status !== "success") return [];
        return [
          {
            bookId: k.bookId,
            epoch: k.epoch,
            cleared: r.result.cleared,
            clearingRateBps: Number(r.result.clearingRateBps),
            clearedAt: BigInt(r.result.clearedAt),
            volume: BigInt(r.result.volume),
            seriesId: r.result.seriesId,
          },
        ];
      }),
    [keys, data],
  );
  return { results, isLoading };
}

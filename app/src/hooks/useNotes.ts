"use client";

import { useMemo } from "react";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import type { Address } from "viem";
import { RepoLockerAbi, RepoNoteAbi } from "@/abi";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

export type Series = {
  id: bigint;
  bookId: number;
  epoch: bigint;
  rateBps: number;
  start: bigint;
  maturity: bigint;
  openRepos: number;
  principal: bigint;
  cash: bigint;
  badDebt: bigint;
  redeemed: bigint;
};

/** Latest series ids (1..nextSeriesId-1), newest first, capped. */
export function useSeriesIds(cap = 400): bigint[] {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { data: next } = useReadContract({
    address: d?.RepoLocker,
    abi: RepoLockerAbi,
    functionName: "nextSeriesId",
    chainId,
    query: { enabled: !!d, refetchInterval: 30_000 },
  });
  return useMemo(() => {
    const n = next ?? 1n;
    const out: bigint[] = [];
    for (let id = n - 1n; id >= 1n && out.length < cap; id--) out.push(id);
    return out;
  }, [next, cap]);
}

export function useSeries(ids: bigint[]): Map<string, Series> {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { data } = useReadContracts({
    contracts: ids.map((id) => ({ address: d?.RepoLocker as Address, abi: RepoLockerAbi, functionName: "getSeries", args: [id], chainId }) as const),
    query: { enabled: !!d && ids.length > 0, refetchInterval: 30_000 },
  });
  return useMemo(() => {
    const m = new Map<string, Series>();
    ids.forEach((id, i) => {
      const r = data?.[i];
      if (r?.status !== "success") return;
      const s = r.result;
      m.set(id.toString(), {
        id,
        bookId: Number(s.bookId),
        epoch: BigInt(s.epoch),
        rateBps: Number(s.rateBps),
        start: BigInt(s.start),
        maturity: BigInt(s.maturity),
        openRepos: Number(s.openRepos),
        principal: BigInt(s.principal),
        cash: BigInt(s.cash),
        badDebt: BigInt(s.badDebt),
        redeemed: BigInt(s.redeemed),
      });
    });
    return m;
  }, [ids, data]);
}

/** The connected account's repo-note balances (series with a non-zero balance). */
export function useMyNotes(): { id: bigint; balance: bigint }[] {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { address } = useAccount();
  const ids = useSeriesIds();
  const { data } = useReadContracts({
    contracts: ids.map(
      (id) => ({ address: d?.RepoNote as Address, abi: RepoNoteAbi, functionName: "balanceOf", args: [address as Address, id], chainId }) as const,
    ),
    query: { enabled: !!d && !!address && ids.length > 0, refetchInterval: 20_000 },
  });
  return useMemo(
    () =>
      ids.flatMap((id, i) => {
        const r = data?.[i];
        return r?.status === "success" && (r.result as bigint) > 0n ? [{ id, balance: r.result as bigint }] : [];
      }),
    [ids, data],
  );
}

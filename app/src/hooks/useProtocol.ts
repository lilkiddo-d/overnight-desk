"use client";

import { useEffect, useMemo, useState } from "react";
import { useBlock, useReadContract, useReadContracts } from "wagmi";
import type { Address } from "viem";
import { ERC20Abi, MarketClockAbi, TermRegistryAbi } from "@/abi";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";
import { epochAt, epochTimes, phaseAt } from "@/lib/math";
import type { ClockParams, EpochTimes, PhaseId } from "@/lib/math";

/** Wall-clock seconds, ticking every second. */
export function useNowSeconds(): bigint {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)));
  useEffect(() => {
    const id = setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 1_000);
    return () => clearInterval(id);
  }, []);
  return now;
}

/**
 * Best estimate of the chain's block.timestamp "now": wall clock, shifted forward if the latest block is ahead of
 * the local clock (e.g. a time-warped local fork or a skewed device clock). An idle chain whose last block is old
 * is assumed to stamp the next block with the current time, as Arbitrum and anvil do.
 */
export function useChainNow(): bigint {
  const chainId = useAppChainId();
  const now = useNowSeconds();
  const { data: block } = useBlock({ chainId, query: { refetchInterval: 15_000 } });
  const [offset, setOffset] = useState(0n);
  useEffect(() => {
    if (!block) return;
    const local = BigInt(Math.floor(Date.now() / 1000));
    const diff = block.timestamp - local;
    setOffset(diff > 5n ? diff : 0n);
  }, [block]);
  return now + offset;
}

export type ClockState = {
  params?: ClockParams;
  now: bigint;
  epoch?: bigint;
  phase?: PhaseId;
  times?: EpochTimes;
  /** on-chain MarketClock.phase(currentEpoch), refreshed every 5s (informational) */
  onchainPhase?: PhaseId;
  timesOf: (epoch: bigint) => EpochTimes | undefined;
  phaseOf: (epoch: bigint) => PhaseId | undefined;
};

/** Auction calendar. Immutable cadence is read once; epochs/phases are derived from chain time like MarketClock. */
export function useClock(): ClockState {
  const chainId = useAppChainId();
  const d = useDeployment();
  const now = useChainNow();
  const clock = d?.MarketClock;
  const base = { address: clock as Address, abi: MarketClockAbi, chainId } as const;
  const { data } = useReadContracts({
    contracts: [
      { ...base, functionName: "genesis" },
      { ...base, functionName: "interval" },
      { ...base, functionName: "commitWindow" },
      { ...base, functionName: "revealWindow" },
      { ...base, functionName: "clearWindow" },
    ],
    query: { enabled: !!clock, staleTime: Infinity },
  });
  const params = useMemo<ClockParams | undefined>(() => {
    if (!data || data.some((r) => r.status !== "success")) return undefined;
    const [g, i, c, r, cl] = data.map((x) => x.result as bigint);
    return { genesis: g, interval: i, commitWindow: c, revealWindow: r, clearWindow: cl };
  }, [data]);

  const epoch = params ? (epochAt(params, now) ?? undefined) : undefined;
  const { data: onchainPhase } = useReadContract({
    ...base,
    functionName: "phase",
    args: [epoch ?? 0n],
    query: { enabled: !!clock && epoch !== undefined, refetchInterval: 5_000 },
  });

  return {
    params,
    now,
    epoch,
    phase: params && epoch !== undefined ? phaseAt(params, epoch, now) : undefined,
    times: params && epoch !== undefined ? epochTimes(params, epoch) : undefined,
    onchainPhase: onchainPhase as PhaseId | undefined,
    timesOf: (e) => (params ? epochTimes(params, e) : undefined),
    phaseOf: (e) => (params ? phaseAt(params, e, now) : undefined),
  };
}

export type TokenMeta = { address: Address; symbol: string; decimals: number };

export type BookInfo = {
  id: number;
  termId: number;
  termLabel: string;
  duration: number;
  collateral: Address;
  collSymbol: string;
  collDecimals: number;
  active: boolean;
  initialHaircutBps: number;
  maintenanceHaircutBps: number;
  liquidationPenaltyBps: number;
  maxCollateralPerAuction: bigint;
};

export type RegistryParams = {
  minOrderSize: bigint;
  maxRateBps: number;
  auctionFeeBpsPerYear: number;
  noRevealPenaltyBps: number;
  maxOrdersPerSide: number;
  marginCallGracePeriod: number;
  maturityGracePeriod: number;
};

/** Stablecoin metadata (symbol/decimals read on-chain). */
export function useStable(): TokenMeta | undefined {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { data } = useReadContracts({
    contracts: [
      { address: d?.stablecoin as Address, abi: ERC20Abi, functionName: "symbol", chainId },
      { address: d?.stablecoin as Address, abi: ERC20Abi, functionName: "decimals", chainId },
    ],
    query: { enabled: !!d, staleTime: Infinity },
  });
  return useMemo(() => {
    if (!d || !data || data[1].status !== "success") return undefined;
    return {
      address: d.stablecoin,
      symbol: data[0].status === "success" ? String(data[0].result) : "USD",
      decimals: Number(data[1].result),
    };
  }, [d, data]);
}

/** Every book with its term and collateral configuration, plus registry params. */
export function useBooks(): {
  books: BookInfo[];
  params?: RegistryParams;
  collaterals: TokenMeta[];
  isLoading: boolean;
} {
  const chainId = useAppChainId();
  const d = useDeployment();
  const reg = { address: d?.TermRegistry as Address, abi: TermRegistryAbi, chainId } as const;

  const { data: head, isLoading: l1 } = useReadContracts({
    contracts: [
      { ...reg, functionName: "bookCount" },
      { ...reg, functionName: "getParams" },
    ],
    query: { enabled: !!d, refetchInterval: 60_000 },
  });
  const count = head?.[0].status === "success" ? Number(head[0].result) : 0;

  const { data: bookData, isLoading: l2 } = useReadContracts({
    contracts: Array.from({ length: count }, (_, i) => ({ ...reg, functionName: "getBook", args: [i] }) as const),
    query: { enabled: !!d && count > 0, refetchInterval: 60_000 },
  });
  const rawBooks = useMemo(
    () =>
      (bookData ?? []).flatMap((r, i) =>
        r.status === "success" ? [{ id: i, termId: Number(r.result.termId), collateral: r.result.collateral, enabled: r.result.enabled }] : [],
      ),
    [bookData],
  );
  const termIds = useMemo(() => [...new Set(rawBooks.map((b) => b.termId))].sort((a, b) => a - b), [rawBooks]);
  const collAddrs = useMemo(() => [...new Set(rawBooks.map((b) => b.collateral))], [rawBooks]);

  const { data: termData, isLoading: l3 } = useReadContracts({
    contracts: termIds.map((t) => ({ ...reg, functionName: "getTerm", args: [t] }) as const),
    query: { enabled: termIds.length > 0, staleTime: 60_000 },
  });
  const { data: collCfg, isLoading: l4 } = useReadContracts({
    contracts: collAddrs.map((a) => ({ ...reg, functionName: "getCollateral", args: [a] }) as const),
    query: { enabled: collAddrs.length > 0, staleTime: 60_000 },
  });
  const { data: collSyms } = useReadContracts({
    contracts: collAddrs.map((a) => ({ address: a, abi: ERC20Abi, functionName: "symbol", chainId }) as const),
    query: { enabled: collAddrs.length > 0, staleTime: Infinity },
  });

  return useMemo(() => {
    const terms = new Map<number, { label: string; duration: number; enabled: boolean }>();
    termIds.forEach((t, i) => {
      const r = termData?.[i];
      if (r?.status === "success") terms.set(t, { label: r.result.label, duration: Number(r.result.duration), enabled: r.result.enabled });
    });
    const colls = new Map<Address, { cfg?: { enabled: boolean; decimals: number; initialHaircutBps: number; maintenanceHaircutBps: number; liquidationPenaltyBps: number; maxCollateralPerAuction: bigint }; symbol: string }>();
    collAddrs.forEach((a, i) => {
      const c = collCfg?.[i];
      const s = collSyms?.[i];
      colls.set(a, {
        cfg: c?.status === "success" ? c.result : undefined,
        symbol: s?.status === "success" ? String(s.result) : a.slice(0, 8),
      });
    });
    // prefer the symbol from the deployment file when the token's own symbol differs (purely cosmetic)
    const books: BookInfo[] = rawBooks.flatMap((b) => {
      const t = terms.get(b.termId);
      const c = colls.get(b.collateral);
      if (!t || !c?.cfg) return [];
      return [
        {
          id: b.id,
          termId: b.termId,
          termLabel: t.label,
          duration: t.duration,
          collateral: b.collateral,
          collSymbol: c.symbol,
          collDecimals: Number(c.cfg.decimals),
          active: b.enabled && t.enabled && c.cfg.enabled,
          initialHaircutBps: Number(c.cfg.initialHaircutBps),
          maintenanceHaircutBps: Number(c.cfg.maintenanceHaircutBps),
          liquidationPenaltyBps: Number(c.cfg.liquidationPenaltyBps),
          maxCollateralPerAuction: BigInt(c.cfg.maxCollateralPerAuction),
        },
      ];
    });
    const p = head?.[1].status === "success" ? head[1].result : undefined;
    const params: RegistryParams | undefined = p
      ? {
          minOrderSize: BigInt(p.minOrderSize),
          maxRateBps: Number(p.maxRateBps),
          auctionFeeBpsPerYear: Number(p.auctionFeeBpsPerYear),
          noRevealPenaltyBps: Number(p.noRevealPenaltyBps),
          maxOrdersPerSide: Number(p.maxOrdersPerSide),
          marginCallGracePeriod: Number(p.marginCallGracePeriod),
          maturityGracePeriod: Number(p.maturityGracePeriod),
        }
      : undefined;
    const collaterals: TokenMeta[] = collAddrs.flatMap((a) => {
      const c = colls.get(a);
      return c?.cfg ? [{ address: a, symbol: c.symbol, decimals: Number(c.cfg.decimals) }] : [];
    });
    return { books, params, collaterals, isLoading: l1 || l2 || l3 || l4 };
  }, [rawBooks, termIds, collAddrs, termData, collCfg, collSyms, head, l1, l2, l3, l4]);
}

export function bookName(b: BookInfo | undefined): string {
  return b ? `${b.collSymbol} · ${b.termLabel}` : "-";
}

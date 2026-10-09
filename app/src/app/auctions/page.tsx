"use client";

import { useMemo, useState } from "react";
import { useReadContracts, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { AuctionHouseAbi } from "@/abi";
import { DeploymentGate } from "@/components/DeploymentGate";
import { TxButton } from "@/components/TxButton";
import { Badge, Countdown, Empty, PhaseBadge } from "@/components/ui";
import { useBooks, useClock, useStable } from "@/hooks/useProtocol";
import type { BookInfo } from "@/hooks/useProtocol";
import { fmtAmount, fmtBps } from "@/lib/format";
import { PHASE } from "@/lib/math";
import type { PhaseId } from "@/lib/math";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

export default function AuctionsPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Auctions</h1>
        <p className="mt-1 text-sm text-muted">
          Every book runs one sealed-bid auction per epoch. Clearing is permissionless: anyone can clear a book during
          its clearing window. If no one does, every order becomes fully refundable at expiry.
        </p>
      </div>
      <DeploymentGate>
        <Auctions />
      </DeploymentGate>
    </div>
  );
}

function Auctions() {
  const chainId = useAppChainId();
  const d = useDeployment();
  const clock = useClock();
  const stable = useStable();
  const { books, isLoading } = useBooks();
  const [filter, setFilter] = useState("");
  const { writeContractAsync } = useWriteContract();

  const epochs = useMemo(() => {
    if (clock.epoch === undefined) return [] as bigint[];
    return clock.epoch > 0n ? [clock.epoch, clock.epoch - 1n] : [clock.epoch];
  }, [clock.epoch]);

  const keys = useMemo(() => books.flatMap((b) => epochs.map((e) => ({ book: b, epoch: e }))), [books, epochs]);
  const ah = { address: d?.AuctionHouse as Address, abi: AuctionHouseAbi, chainId } as const;
  const { data } = useReadContracts({
    contracts: keys.flatMap(
      (k) =>
        [
          { ...ah, functionName: "bookOrders", args: [k.book.id, k.epoch] },
          { ...ah, functionName: "getResult", args: [k.book.id, k.epoch] },
        ] as const,
    ),
    query: { enabled: !!d && keys.length > 0, refetchInterval: 10_000 },
  });

  const rows = keys.map((k, i) => {
    const bo = data?.[i * 2];
    const rs = data?.[i * 2 + 1];
    const orders = bo?.status === "success" ? (bo.result as readonly [readonly bigint[], readonly bigint[]]) : undefined;
    const result =
      rs?.status === "success"
        ? (rs.result as { cleared: boolean; clearingRateBps: number; clearedAt: bigint; volume: bigint; seriesId: bigint })
        : undefined;
    return { ...k, lends: orders?.[0].length, borrows: orders?.[1].length, result };
  });

  const symbols = [...new Set(books.map((b) => b.collSymbol))];
  const shown = rows.filter((r) => !filter || r.book.collSymbol === filter);

  if (!isLoading && books.length === 0) return <Empty>No books configured.</Empty>;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <select className="input w-auto" value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="Filter collateral">
          <option value="">All collateral</option>
          {symbols.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
        <span className="text-sm text-muted">
          Current epoch <span className="font-mono text-fg">{clock.epoch?.toString() ?? "-"}</span>
        </span>
      </div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {shown.map((r) => (
          <AuctionCard
            key={`${r.book.id}-${r.epoch}`}
            book={r.book}
            epoch={r.epoch}
            phase={clock.phaseOf(r.epoch)}
            times={clock.timesOf(r.epoch)}
            now={clock.now}
            lends={r.lends}
            borrows={r.borrows}
            result={r.result}
            stableDecimals={stable?.decimals}
            stableSymbol={stable?.symbol}
            onClear={() =>
              writeContractAsync({ address: d!.AuctionHouse, abi: AuctionHouseAbi, functionName: "clear", args: [r.book.id, r.epoch], chainId })
            }
          />
        ))}
      </div>
    </div>
  );
}

function AuctionCard(p: {
  book: BookInfo;
  epoch: bigint;
  phase: PhaseId | undefined;
  times: ReturnType<ReturnType<typeof useClock>["timesOf"]>;
  now: bigint;
  lends?: number;
  borrows?: number;
  result?: { cleared: boolean; clearingRateBps: number; volume: bigint; seriesId: bigint };
  stableDecimals?: number;
  stableSymbol?: string;
  onClear: () => Promise<`0x${string}`>;
}) {
  const t = p.times;
  const next =
    p.phase === PHASE.Commit ? t?.commitEnd : p.phase === PHASE.Reveal ? t?.revealEnd : p.phase === PHASE.Clearing ? t?.expiry : p.phase === PHASE.Pending ? t?.start : undefined;
  const nextLabel =
    p.phase === PHASE.Commit ? "reveal in" : p.phase === PHASE.Reveal ? "clearing in" : p.phase === PHASE.Clearing ? "expires in" : p.phase === PHASE.Pending ? "opens in" : "";
  const cleared = p.result?.cleared ?? false;
  const canClear = p.phase === PHASE.Clearing && !cleared;
  return (
    <div className="card space-y-2">
      <div className="flex items-center justify-between gap-2">
        <div className="min-w-0">
          <div className="truncate font-semibold">
            {p.book.collSymbol} · {p.book.termLabel}
          </div>
          <div className="text-xs text-muted">
            Book {p.book.id} · epoch {p.epoch.toString()}
            {!p.book.active && " · disabled"}
          </div>
        </div>
        <PhaseBadge phase={p.phase} />
      </div>
      <div className="grid grid-cols-3 gap-2 text-xs">
        <div>
          <div className="text-muted">Lend orders</div>
          <div className="text-sm tabular-nums">{p.lends ?? "-"}</div>
        </div>
        <div>
          <div className="text-muted">Borrow orders</div>
          <div className="text-sm tabular-nums">{p.borrows ?? "-"}</div>
        </div>
        <div>
          <div className="text-muted">{nextLabel || "status"}</div>
          <div className="text-sm">{next !== undefined ? <Countdown to={next} now={p.now} /> : "-"}</div>
        </div>
      </div>
      <div className="flex min-h-6 flex-wrap items-center gap-2 text-xs">
        {cleared ? (
          p.result && p.result.volume > 0n ? (
            <>
              <Badge tone="good">Cleared {fmtBps(p.result.clearingRateBps)}</Badge>
              <span>
                {fmtAmount(p.result.volume, p.stableDecimals, 2)} {p.stableSymbol}
              </span>
              <span className="text-muted">series #{p.result.seriesId.toString()}</span>
            </>
          ) : (
            <Badge tone="muted">Cleared · no match</Badge>
          )
        ) : p.phase === PHASE.Expired ? (
          <Badge tone="warn">Expired uncleared · refundable</Badge>
        ) : (
          <Badge tone="muted">Not cleared</Badge>
        )}
      </div>
      {canClear && <TxButton small label="Clear auction" requireRiskAck={false} action={p.onClear} />}
    </div>
  );
}

"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { DeploymentGate } from "@/components/DeploymentGate";
import { RateChart } from "@/components/RateChart";
import type { CurvePoint } from "@/components/RateChart";
import { Card, Countdown, Empty, PhaseBadge, Stat } from "@/components/ui";
import { useBooks, useClock, useStable, bookName } from "@/hooks/useProtocol";
import { useRecentResults } from "@/hooks/useResults";
import { fmtAmount, fmtBps, fmtDuration, fmtTime } from "@/lib/format";
import { PHASE_NAMES } from "@/lib/math";

export default function DashboardPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Overnight Desk</h1>
        <p className="mt-1 text-sm text-muted">
          Fixed-term, fixed-rate repo loans against tokenized stocks, priced by sealed-bid uniform-price auctions.
        </p>
      </div>
      <DeploymentGate>
        <Dashboard />
      </DeploymentGate>
    </div>
  );
}

function Dashboard() {
  const clock = useClock();
  const stable = useStable();
  const { books, collaterals, isLoading } = useBooks();
  const [collChoice, setCollChoice] = useState<string>("");
  const selected = collChoice || collaterals[0]?.address || "";
  const { results } = useRecentResults(books, clock.epoch, 10);

  const curve = useMemo<CurvePoint[]>(() => {
    const bs = books.filter((b) => b.collateral === selected).sort((a, b) => a.duration - b.duration);
    return bs.map((b) => {
      const last = results
        .filter((r) => r.bookId === b.id && r.cleared && r.volume > 0n)
        .sort((x, y) => (y.epoch > x.epoch ? 1 : -1))[0];
      return { label: b.termLabel || fmtDuration(b.duration), duration: b.duration, rateBps: last ? last.clearingRateBps : null, epoch: last?.epoch };
    });
  }, [books, results, selected]);

  const recent = useMemo(
    () =>
      results
        .filter((r) => r.cleared)
        .sort((a, b) => (b.clearedAt > a.clearedAt ? 1 : b.clearedAt < a.clearedAt ? -1 : 0))
        .slice(0, 20),
    [results],
  );
  const bookById = useMemo(() => new Map(books.map((b) => [b.id, b])), [books]);
  const t = clock.times;

  return (
    <div className="grid gap-6 lg:grid-cols-3">
      <Card title="Current auction" className="lg:col-span-1">
        <div className="space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-sm text-muted">Epoch</span>
            <span className="font-mono">{clock.epoch?.toString() ?? "-"}</span>
          </div>
          <div className="flex items-center justify-between">
            <span className="text-sm text-muted">Phase</span>
            <span className="flex items-center gap-2">
              <PhaseBadge phase={clock.phase} />
              {clock.onchainPhase !== undefined && clock.onchainPhase !== clock.phase && (
                <span className="text-xs text-muted">on-chain: {PHASE_NAMES[clock.onchainPhase]}</span>
              )}
            </span>
          </div>
          <div className="grid grid-cols-3 gap-2 pt-2">
            <Stat label="Commit ends" value={<Countdown to={t?.commitEnd} now={clock.now} />} />
            <Stat label="Reveal ends" value={<Countdown to={t?.revealEnd} now={clock.now} />} />
            <Stat label="Expiry" value={<Countdown to={t?.expiry} now={clock.now} />} />
          </div>
          {clock.params && (
            <p className="text-xs text-muted">
              A new auction every {fmtDuration(clock.params.interval)}: commit {fmtDuration(clock.params.commitWindow)}, reveal{" "}
              {fmtDuration(clock.params.revealWindow)}, clearing {fmtDuration(clock.params.clearWindow)}.
            </p>
          )}
          <Link href="/trade" className="btn-primary w-full">
            Place an order
          </Link>
        </div>
      </Card>

      <Card
        title="Rate curve (last clearing rate)"
        className="lg:col-span-2"
        actions={
          <select className="input w-auto" value={selected} onChange={(e) => setCollChoice(e.target.value)} aria-label="Collateral">
            {collaterals.map((c) => (
              <option key={c.address} value={c.address}>
                {c.symbol}
              </option>
            ))}
          </select>
        }
      >
        {isLoading && curve.length === 0 ? (
          <Empty>Loading books…</Empty>
        ) : curve.length === 0 ? (
          <Empty>No books for this collateral.</Empty>
        ) : (
          <>
            <RateChart points={curve} />
            <p className="mt-2 text-xs text-muted">
              Latest non-zero clearing rate per term within the last 10 auctions. Annualised, simple interest (ACT/365).
            </p>
          </>
        )}
      </Card>

      <Card title="Recent results" className="lg:col-span-3">
        {recent.length === 0 ? (
          <Empty>No auctions cleared in the last 10 epochs.</Empty>
        ) : (
          <div className="-mx-2 overflow-x-auto">
            <table className="table">
              <thead>
                <tr>
                  <th>Book</th>
                  <th>Epoch</th>
                  <th>Rate</th>
                  <th>Volume</th>
                  <th>Series</th>
                  <th>Cleared</th>
                </tr>
              </thead>
              <tbody>
                {recent.map((r) => (
                  <tr key={`${r.bookId}-${r.epoch}`}>
                    <td>{bookName(bookById.get(r.bookId))}</td>
                    <td className="font-mono">{r.epoch.toString()}</td>
                    <td>{r.volume > 0n ? fmtBps(r.clearingRateBps) : <span className="text-muted">no match</span>}</td>
                    <td>
                      {fmtAmount(r.volume, stable?.decimals, 2)} {stable?.symbol}
                    </td>
                    <td className="font-mono">{r.seriesId > 0n ? `#${r.seriesId}` : "-"}</td>
                    <td>{fmtTime(r.clearedAt)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}

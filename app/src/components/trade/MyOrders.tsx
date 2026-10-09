"use client";

import { useMemo, useRef, useState } from "react";
import { useAccount, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { AuctionHouseAbi } from "@/abi";
import { TxButton } from "@/components/TxButton";
import { Badge, Card, Empty, Notice, PhaseBadge } from "@/components/ui";
import { useStoredOrders } from "@/hooks/useOrderStore";
import { bookName, useBooks, useClock, useStable } from "@/hooks/useProtocol";
import { fmtAmount, fmtBps, fmtCountdown } from "@/lib/format";
import { PHASE } from "@/lib/math";
import { downloadJson, exportBackup, importBackup } from "@/lib/orderStore";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

const STATE_NAMES = ["None", "Committed", "Revealed", "Settled", "Cancelled"] as const;
const MAX_ROWS = 60;

export function MyOrders() {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { address } = useAccount();
  const clock = useClock();
  const stable = useStable();
  const { books } = useBooks();
  const stored = useStoredOrders();
  const { writeContractAsync } = useWriteContract();
  const fileRef = useRef<HTMLInputElement>(null);
  const [importMsg, setImportMsg] = useState<string | null>(null);
  const [showClosed, setShowClosed] = useState(false);

  const { data: ids } = useReadContract({
    address: d?.AuctionHouse,
    abi: AuctionHouseAbi,
    functionName: "ordersOf",
    args: [address as Address],
    chainId,
    query: { enabled: !!d && !!address, refetchInterval: 15_000 },
  });
  const recentIds = useMemo(() => [...(ids ?? [])].reverse().slice(0, MAX_ROWS), [ids]);
  const { data: orderData } = useReadContracts({
    contracts: recentIds.map(
      (id) => ({ address: d?.AuctionHouse as Address, abi: AuctionHouseAbi, functionName: "getOrder", args: [id], chainId }) as const,
    ),
    query: { enabled: !!d && recentIds.length > 0, refetchInterval: 15_000 },
  });
  const orders = useMemo(
    () => recentIds.flatMap((id, i) => (orderData?.[i]?.status === "success" ? [{ id, ...orderData[i].result! }] : [])),
    [recentIds, orderData],
  );
  const pairs = useMemo(() => {
    const m = new Map<string, { bookId: number; epoch: bigint }>();
    orders.forEach((o) => m.set(`${o.bookId}:${o.epoch}`, { bookId: o.bookId, epoch: o.epoch }));
    return [...m.values()];
  }, [orders]);
  const { data: resultData } = useReadContracts({
    contracts: pairs.map(
      (p) => ({ address: d?.AuctionHouse as Address, abi: AuctionHouseAbi, functionName: "getResult", args: [p.bookId, p.epoch], chainId }) as const,
    ),
    query: { enabled: !!d && pairs.length > 0, refetchInterval: 15_000 },
  });
  const cleared = useMemo(() => {
    const m = new Map<string, boolean>();
    pairs.forEach((p, i) => m.set(`${p.bookId}:${p.epoch}`, resultData?.[i]?.status === "success" ? resultData[i].result!.cleared : false));
    return m;
  }, [pairs, resultData]);

  const bookById = useMemo(() => new Map(books.map((b) => [b.id, b])), [books]);
  const secrets = useMemo(() => {
    const m = new Map<string, (typeof stored)[number]>();
    stored.forEach((s) => m.set(s.commitment.toLowerCase(), s));
    return m;
  }, [stored]);
  const mySecrets = stored.filter((s) => s.chainId === chainId && s.account.toLowerCase() === address?.toLowerCase());

  const visible = orders.filter((o) => showClosed || o.state === 1 || o.state === 2);
  const missingSecret = orders.filter(
    (o) => o.state === 1 && !secrets.has(o.commitment.toLowerCase()) && (clock.phaseOf(o.epoch) ?? 0) <= PHASE.Reveal,
  );

  function onImport(file: File) {
    file
      .text()
      .then((t) => {
        const r = importBackup(t);
        setImportMsg(`Imported ${r.imported} order(s)${r.rejected ? `, rejected ${r.rejected} invalid record(s)` : ""}.`);
      })
      .catch(() => setImportMsg("Could not read that file. Is it an Overnight Desk backup?"));
  }

  return (
    <Card
      title="My orders"
      actions={
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            className="btn-secondary px-3 py-1.5 text-xs"
            disabled={!address || mySecrets.length === 0}
            onClick={() => address && downloadJson(`overnight-desk-orders-${chainId}-${address.slice(2, 8)}.json`, exportBackup({ chainId, account: address }))}
          >
            Download backup (JSON)
          </button>
          <button type="button" className="btn-secondary px-3 py-1.5 text-xs" onClick={() => fileRef.current?.click()}>
            Import backup
          </button>
          <input
            ref={fileRef}
            type="file"
            accept="application/json,.json"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) onImport(f);
              e.target.value = "";
            }}
          />
        </div>
      }
    >
      <div className="space-y-3">
        {importMsg && <Notice>{importMsg}</Notice>}
        {missingSecret.length > 0 && (
          <Notice tone="bad">
            <strong>Missing reveal data for order(s) {missingSecret.map((o) => `#${o.id}`).join(", ")}.</strong> The rate and
            salt are not in this browser. Import your backup before the reveal window ends, or the order forfeits{" "}
            1% of its escrow when settled.
          </Notice>
        )}
        {!address ? (
          <Empty>Connect a wallet to see your orders.</Empty>
        ) : orders.length === 0 ? (
          <Empty>No orders yet.</Empty>
        ) : (
          <>
            <label className="flex items-center gap-2 text-xs text-muted">
              <input type="checkbox" checked={showClosed} onChange={(e) => setShowClosed(e.target.checked)} /> Show settled and
              cancelled orders
            </label>
            {visible.length === 0 && <Empty>No open orders.</Empty>}
            <ul className="space-y-3">
              {visible.map((o) => {
                const b = bookById.get(o.bookId);
                const phase = clock.phaseOf(o.epoch);
                const t = clock.timesOf(o.epoch);
                const secret = secrets.get(o.commitment.toLowerCase());
                const isCleared = cleared.get(`${o.bookId}:${o.epoch}`) ?? false;
                const now = clock.now;
                const canReveal = o.state === 1 && phase === PHASE.Reveal;
                // includes orders rolled into a future epoch (Pending), which can be opted out of until its commit end
                const canCancel = (o.state === 1 || o.state === 2) && !!t && now < t.commitEnd;
                const canSettle =
                  !!t &&
                  ((o.state === 1 && now >= t.revealEnd) || (o.state === 2 && (isCleared || now >= t.expiry)));
                const isLend = o.side === 0;
                const rate = o.state >= 2 && o.rateBps > 0 ? fmtBps(o.rateBps) : secret ? `${fmtBps(secret.rateBps)} (sealed)` : "sealed";
                return (
                  <li key={o.id.toString()} className="rounded-lg border border-line bg-panel2/50 p-3">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-mono text-sm">#{o.id.toString()}</span>
                      <Badge tone={isLend ? "info" : "warn"}>{isLend ? "Lend" : "Borrow"}</Badge>
                      <span className="text-sm">{bookName(b)}</span>
                      <span className="text-xs text-muted">epoch {o.epoch.toString()}</span>
                      <PhaseBadge phase={phase} />
                      <Badge tone={o.state === 3 ? "good" : o.state === 4 ? "muted" : "info"}>{STATE_NAMES[o.state] ?? o.state}</Badge>
                      {o.isRepoRoll && <Badge tone="muted">repo roll</Badge>}
                      {o.rollover && <Badge tone="muted">rollover</Badge>}
                    </div>
                    <div className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-4">
                      <div>
                        <span className="text-muted">Amount </span>
                        {fmtAmount(o.amount, stable?.decimals, 2)} {stable?.symbol}
                      </div>
                      <div>
                        <span className="text-muted">Rate </span>
                        {rate}
                      </div>
                      {!isLend && (
                        <div>
                          <span className="text-muted">Collateral </span>
                          {fmtAmount(o.collateral, b?.collDecimals)} {b?.collSymbol}
                        </div>
                      )}
                      <div>
                        <span className="text-muted">Filled </span>
                        {fmtAmount(o.filled, stable?.decimals, 2)}
                      </div>
                      {o.rolledInto > 0n && (
                        <div>
                          <span className="text-muted">Rolled into </span>#{o.rolledInto.toString()}
                        </div>
                      )}
                      {o.repoId > 0n && !isLend && (
                        <div>
                          <span className="text-muted">Repo </span>#{o.repoId.toString()}
                        </div>
                      )}
                    </div>
                    {o.state === 1 && !secret && (
                      <p className="mt-2 text-xs font-semibold text-bad">
                        Reveal data missing in this browser. Import your backup or this order loses 1% when settled.
                      </p>
                    )}
                    {canReveal && t && (
                      <p className="mt-2 text-xs text-warn">Reveal window closes in {fmtCountdown(t.revealEnd - now)}.</p>
                    )}
                    <div className="mt-3 flex flex-wrap gap-2">
                      {canReveal && (
                        <TxButton
                          small
                          label="Reveal"
                          requireRiskAck={false}
                          disabled={!secret}
                          disabledReason={secret ? undefined : "Import your backup to reveal"}
                          action={() =>
                            writeContractAsync({
                              address: d!.AuctionHouse,
                              abi: AuctionHouseAbi,
                              functionName: "reveal",
                              args: [o.id, secret!.rateBps, secret!.salt],
                              chainId,
                            })
                          }
                        />
                      )}
                      {canCancel && (
                        <TxButton
                          small
                          variant="secondary"
                          label="Cancel"
                          requireRiskAck={false}
                          action={() =>
                            writeContractAsync({ address: d!.AuctionHouse, abi: AuctionHouseAbi, functionName: "cancel", args: [o.id], chainId })
                          }
                        />
                      )}
                      {canSettle && (
                        <TxButton
                          small
                          label="Settle"
                          requireRiskAck={false}
                          action={() =>
                            writeContractAsync({ address: d!.AuctionHouse, abi: AuctionHouseAbi, functionName: "settle", args: [o.id], chainId })
                          }
                        />
                      )}
                    </div>
                  </li>
                );
              })}
            </ul>
            {(ids?.length ?? 0) > MAX_ROWS && <p className="text-xs text-muted">Showing your latest {MAX_ROWS} orders.</p>}
          </>
        )}
        <p className="text-xs text-muted">{mySecrets.length} order secret(s) stored in this browser for this wallet and network.</p>
      </div>
    </Card>
  );
}

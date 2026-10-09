"use client";

import { useMemo, useState } from "react";
import { useAccount, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { NoteMarketAbi, RepoNoteAbi } from "@/abi";
import { DeploymentGate } from "@/components/DeploymentGate";
import { TxButton } from "@/components/TxButton";
import { Badge, Card, Empty, Field } from "@/components/ui";
import { useMyNotes, useSeries } from "@/hooks/useNotes";
import type { Series } from "@/hooks/useNotes";
import { bookName, useBooks, useClock, useStable } from "@/hooks/useProtocol";
import type { BookInfo, TokenMeta } from "@/hooks/useProtocol";
import { fmtAmount, fmtBps, fmtPct, fmtTime, parseAmount, shortAddr } from "@/lib/format";
import { E18, noteYield } from "@/lib/math";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

const MAX_LISTINGS = 200;

type Listing = { id: bigint; seller: Address; seriesId: bigint; amount: bigint; priceE18: bigint; active: boolean };

export default function NotesPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Note market</h1>
        <p className="mt-1 text-sm text-muted">
          Repo notes are transferable claims on a repo series. Sell yours to exit before maturity, or buy notes at a
          discount. One note unit is one unit of lent principal; at maturity it is expected to redeem for principal plus
          interest at the series rate, less any losses.
        </p>
      </div>
      <DeploymentGate>
        <Market />
      </DeploymentGate>
    </div>
  );
}

function useListings(): { listings: Listing[]; feeBps?: number } {
  const chainId = useAppChainId();
  const d = useDeployment();
  const nm = { address: d?.NoteMarket as Address, abi: NoteMarketAbi, chainId } as const;
  const { data: head } = useReadContracts({
    contracts: [
      { ...nm, functionName: "nextListingId" },
      { ...nm, functionName: "feeBps" },
    ],
    query: { enabled: !!d, refetchInterval: 15_000 },
  });
  const next = head?.[0].status === "success" ? (head[0].result as bigint) : 1n;
  const feeBps = head?.[1].status === "success" ? Number(head[1].result) : undefined;
  const ids = useMemo(() => {
    const out: bigint[] = [];
    for (let id = next - 1n; id >= 1n && out.length < MAX_LISTINGS; id--) out.push(id);
    return out;
  }, [next]);
  const { data } = useReadContracts({
    contracts: ids.map((id) => ({ ...nm, functionName: "getListing", args: [id] }) as const),
    query: { enabled: !!d && ids.length > 0, refetchInterval: 15_000 },
  });
  const listings = useMemo(
    () =>
      ids.flatMap((id, i) => {
        const r = data?.[i];
        if (r?.status !== "success") return [];
        const l = r.result as unknown as Omit<Listing, "id">;
        return [{ id, seller: l.seller, seriesId: l.seriesId, amount: BigInt(l.amount), priceE18: BigInt(l.priceE18), active: l.active }];
      }),
    [ids, data],
  );
  return { listings, feeBps };
}

function Market() {
  const { address } = useAccount();
  const clock = useClock();
  const stable = useStable();
  const { books } = useBooks();
  const { listings, feeBps } = useListings();
  const myNotes = useMyNotes();
  const active = listings.filter((l) => l.active && l.amount > 0n);
  const seriesIds = useMemo(() => {
    const s = new Set<string>();
    active.forEach((l) => s.add(l.seriesId.toString()));
    myNotes.forEach((n) => s.add(n.id.toString()));
    return [...s].map((x) => BigInt(x));
  }, [active, myNotes]);
  const series = useSeries(seriesIds);
  const bookById = useMemo(() => new Map(books.map((b) => [b.id, b])), [books]);
  const mine = active.filter((l) => address && l.seller.toLowerCase() === address.toLowerCase());
  const others = active.filter((l) => !address || l.seller.toLowerCase() !== address.toLowerCase());

  return (
    <div className="space-y-6">
      <Card title="Listings">
        {feeBps !== undefined && <p className="mb-3 text-xs text-muted">Market fee {fmtBps(feeBps)} of the purchase cost, paid by the buyer.</p>}
        {others.length === 0 ? (
          <Empty>No notes listed for sale.</Empty>
        ) : (
          <div className="space-y-3">
            {others.map((l) => (
              <ListingRow key={l.id.toString()} l={l} s={series.get(l.seriesId.toString())} book={bookOf(series.get(l.seriesId.toString()), bookById)} stable={stable} now={clock.now} />
            ))}
          </div>
        )}
      </Card>

      {address && (
        <Card title="My listings">
          {mine.length === 0 ? (
            <Empty>You have no active listings.</Empty>
          ) : (
            <div className="space-y-3">
              {mine.map((l) => (
                <ListingRow key={l.id.toString()} l={l} s={series.get(l.seriesId.toString())} book={bookOf(series.get(l.seriesId.toString()), bookById)} stable={stable} now={clock.now} own />
              ))}
            </div>
          )}
        </Card>
      )}

      {address && (
        <Card title="Sell my notes">
          {myNotes.length === 0 ? (
            <Empty>You hold no repo notes.</Empty>
          ) : (
            <div className="space-y-3">
              {myNotes.map((n) => (
                <SellRow key={n.id.toString()} id={n.id} balance={n.balance} s={series.get(n.id.toString())} book={bookOf(series.get(n.id.toString()), bookById)} stable={stable} now={clock.now} />
              ))}
            </div>
          )}
        </Card>
      )}
    </div>
  );
}

function bookOf(s: Series | undefined, m: Map<number, BookInfo>) {
  return s ? m.get(s.bookId) : undefined;
}

function SeriesInfo({ s, book, now }: { s?: Series; book?: BookInfo; now: bigint }) {
  if (!s) return <span className="text-xs text-muted">loading series…</span>;
  return (
    <span className="text-xs text-muted">
      {bookName(book)} · series #{s.id.toString()} · {fmtBps(s.rateBps)} · matures {fmtTime(s.maturity)}
      {now >= s.maturity && " (matured)"}
      {s.badDebt > 0n && <span className="ml-1 text-bad">· bad debt</span>}
    </span>
  );
}

function ListingRow({ l, s, book, stable, now, own }: { l: Listing; s?: Series; book?: BookInfo; stable?: TokenMeta; now: bigint; own?: boolean }) {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { writeContractAsync } = useWriteContract();
  const [amtStr, setAmtStr] = useState("");
  const [newPrice, setNewPrice] = useState("");
  const sd = stable?.decimals ?? 6;
  const y = s ? noteYield(l.priceE18, s.rateBps, s.start, s.maturity, now) : undefined;
  const amt = parseAmount(amtStr, sd);
  const buyAmt = amt && amt > 0n ? (amt > l.amount ? l.amount : amt) : 0n;
  const { data: quote } = useReadContract({
    address: d?.NoteMarket,
    abi: NoteMarketAbi,
    functionName: "quote",
    args: [l.id, buyAmt],
    chainId,
    query: { enabled: !!d && buyAmt > 0n },
  });
  const cost = quote?.[0];
  const fee = quote?.[1];
  const np = parseAmount(newPrice, 18);

  return (
    <div className="rounded-lg border border-line bg-panel2/50 p-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-sm">#{l.id.toString()}</span>
        <SeriesInfo s={s} book={book} now={now} />
        {!own && <span className="text-xs text-muted">seller {shortAddr(l.seller)}</span>}
      </div>
      <div className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-4">
        <div>
          <span className="text-muted">Available </span>
          {fmtAmount(l.amount, sd, 2)} units
        </div>
        <div>
          <span className="text-muted">Price </span>
          {fmtAmount(l.priceE18, 18, 6)} {stable?.symbol}/unit
        </div>
        <div>
          <span className="text-muted">Value at maturity </span>
          {y ? y.valueAtMaturity.toFixed(6) : "-"}
        </div>
        <div>
          <span className="text-muted">Implied yield </span>
          {y ? (y.annualizedYield === null ? "matured" : <Badge tone={y.annualizedYield >= 0 ? "good" : "bad"}>{fmtPct(y.annualizedYield)}</Badge>) : "-"}
        </div>
      </div>
      {d && stable && !own && (
        <div className="mt-3 grid gap-3 sm:grid-cols-3">
          <Field label="Units to buy">
            <div className="flex gap-2">
              <input className="input" inputMode="decimal" value={amtStr} onChange={(e) => setAmtStr(e.target.value)} placeholder="0.00" />
              <button type="button" className="btn-secondary shrink-0 px-3 text-xs" onClick={() => setAmtStr(fmtAmount(l.amount, sd, sd).replace(/,/g, ""))}>
                Max
              </button>
            </div>
          </Field>
          <div className="flex flex-col justify-end text-xs text-muted">
            {cost !== undefined ? (
              <>
                <span>
                  Cost {fmtAmount(cost, sd, 4)} {stable.symbol}
                </span>
                <span>incl. fee {fmtAmount(fee, sd, 4)}</span>
              </>
            ) : (
              <span>Enter an amount for a quote</span>
            )}
          </div>
          <div className="flex items-end">
            <TxButton
              small
              label="Buy"
              approval={cost ? { token: stable.address, spender: d.NoteMarket, amount: cost, symbol: stable.symbol, decimals: sd } : undefined}
              disabled={buyAmt === 0n || cost === undefined}
              disabledReason={buyAmt === 0n ? "Enter an amount" : undefined}
              action={() =>
                writeContractAsync({
                  address: d.NoteMarket,
                  abi: NoteMarketAbi,
                  functionName: "buy",
                  // max price = the price we were quoted, so a seller re-pricing cannot charge more
                  args: [l.id, buyAmt, l.priceE18, BigInt(Math.floor(Date.now() / 1000)) + 300n],
                  chainId,
                })
              }
            />
          </div>
        </div>
      )}
      {d && own && (
        <div className="mt-3 flex flex-wrap items-end gap-3">
          <Field label="New price per unit" hint={s && np ? `Implied yield ${fmtPct(noteYield(np, s.rateBps, s.start, s.maturity, now).annualizedYield)}` : undefined}>
            <input className="input w-36" inputMode="decimal" value={newPrice} onChange={(e) => setNewPrice(e.target.value)} placeholder="0.995" />
          </Field>
          <TxButton
            small
            variant="secondary"
            label="Update price"
            disabled={!np}
            action={() => writeContractAsync({ address: d.NoteMarket, abi: NoteMarketAbi, functionName: "updatePrice", args: [l.id, np!], chainId })}
          />
          <TxButton
            small
            variant="danger"
            label="Cancel listing"
            requireRiskAck={false}
            action={() => writeContractAsync({ address: d.NoteMarket, abi: NoteMarketAbi, functionName: "cancel", args: [l.id], chainId })}
          />
        </div>
      )}
    </div>
  );
}

function SellRow({ id, balance, s, book, stable, now }: { id: bigint; balance: bigint; s?: Series; book?: BookInfo; stable?: TokenMeta; now: bigint }) {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { address } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const [amtStr, setAmtStr] = useState("");
  const [priceStr, setPriceStr] = useState("");
  const sd = stable?.decimals ?? 6;
  const amt = parseAmount(amtStr, sd);
  const priceE18 = parseAmount(priceStr, 18);
  const y = s && priceE18 ? noteYield(priceE18, s.rateBps, s.start, s.maturity, now) : undefined;
  const { data: approved } = useReadContract({
    address: d?.RepoNote,
    abi: RepoNoteAbi,
    functionName: "isApprovedForAll",
    args: [address as Address, d?.NoteMarket as Address],
    chainId,
    query: { enabled: !!d && !!address },
  });
  const invalid = !amt || amt > balance || !priceE18 || priceE18 === 0n;

  return (
    <div className="rounded-lg border border-line bg-panel2/50 p-3">
      <div className="flex flex-wrap items-center gap-2">
        <SeriesInfo s={s} book={book} now={now} />
        <span className="text-xs">balance {fmtAmount(balance, sd, 2)} units</span>
      </div>
      {d && (
        <div className="mt-3 grid gap-3 sm:grid-cols-3">
          <Field label="Units to list">
            <div className="flex gap-2">
              <input className="input" inputMode="decimal" value={amtStr} onChange={(e) => setAmtStr(e.target.value)} placeholder="0.00" />
              <button type="button" className="btn-secondary shrink-0 px-3 text-xs" onClick={() => setAmtStr(fmtAmount(balance, sd, sd).replace(/,/g, ""))}>
                Max
              </button>
            </div>
          </Field>
          <Field
            label={`Price per unit (${stable?.symbol ?? ""})`}
            hint={y ? `Buyer's implied yield ${fmtPct(y.annualizedYield)} · par value at maturity ${y.valueAtMaturity.toFixed(6)}` : "e.g. 0.995"}
          >
            <input className="input" inputMode="decimal" value={priceStr} onChange={(e) => setPriceStr(e.target.value)} placeholder="0.995" />
          </Field>
          <div className="flex items-end">
            <TxButton
              small
              label="List"
              disabled={invalid}
              disabledReason={amt && amt > balance ? "Amount exceeds balance" : undefined}
              preStep={{
                needed: approved === false,
                label: "Approve note market",
                run: () => writeContractAsync({ address: d.RepoNote, abi: RepoNoteAbi, functionName: "setApprovalForAll", args: [d.NoteMarket, true], chainId }),
              }}
              action={() => writeContractAsync({ address: d.NoteMarket, abi: NoteMarketAbi, functionName: "list", args: [id, amt!, priceE18!], chainId })}
            />
          </div>
        </div>
      )}
      {priceE18 !== null && priceE18 > 2n * E18 && <p className="mt-2 text-xs text-warn">That price is more than 2 per unit. Check the decimal point.</p>}
    </div>
  );
}

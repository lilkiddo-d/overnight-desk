"use client";

import { useMemo, useState } from "react";
import { useReadContract, useReadContracts, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { LiquidatorAbi } from "@/abi";
import { TxButton } from "@/components/TxButton";
import { Badge, Card, Countdown, Empty, Field } from "@/components/ui";
import { useBooks, useClock, useStable } from "@/hooks/useProtocol";
import type { TokenMeta } from "@/hooks/useProtocol";
import { fmtAmount, fmtUsdE18, parseAmount, shortAddr } from "@/lib/format";
import { BPS, collateralFor, collateralValue, mulDiv, percentToBps } from "@/lib/math";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

const MAX_AUCTIONS = 100;

type Auction = {
  repoId: bigint;
  collateral: Address;
  borrower: Address;
  collDecimals: number;
  active: boolean;
  startTime: bigint;
  collateralLeft: bigint;
  debtLeft: bigint;
  penaltyLeft: bigint;
  startPrice: bigint;
  floorPrice: bigint;
};

export function LiquidationAuctions() {
  const chainId = useAppChainId();
  const d = useDeployment();
  const stable = useStable();
  const { collaterals } = useBooks();
  const [showAll, setShowAll] = useState(false);
  const liq = { address: d?.Liquidator as Address, abi: LiquidatorAbi, chainId } as const;

  const { data: head } = useReadContracts({
    contracts: [
      { ...liq, functionName: "nextAuctionId" },
      { ...liq, functionName: "duration" },
    ],
    query: { enabled: !!d, refetchInterval: 20_000 },
  });
  const next = head?.[0].status === "success" ? (head[0].result as bigint) : 1n;
  const duration = head?.[1].status === "success" ? BigInt(head[1].result as number) : undefined;
  const ids = useMemo(() => {
    const out: bigint[] = [];
    for (let id = next - 1n; id >= 1n && out.length < MAX_AUCTIONS; id--) out.push(id);
    return out;
  }, [next]);

  const { data } = useReadContracts({
    contracts: ids.flatMap(
      (id) =>
        [
          { ...liq, functionName: "getAuction", args: [id] },
          { ...liq, functionName: "currentPrice", args: [id] },
        ] as const,
    ),
    query: { enabled: !!d && ids.length > 0, refetchInterval: 10_000 },
  });
  const auctions = ids.flatMap((id, i) => {
    const a = data?.[i * 2];
    const p = data?.[i * 2 + 1];
    if (a?.status !== "success") return [];
    return [{ id, a: a.result as unknown as Auction, price: p?.status === "success" ? (p.result as bigint) : undefined }];
  });
  const visible = auctions.filter((x) => showAll || x.a.active);
  const symOf = (addr: Address) => collaterals.find((c) => c.address.toLowerCase() === addr.toLowerCase());

  return (
    <Card
      title="Liquidation auctions"
      actions={
        <label className="flex items-center gap-2 text-xs text-muted">
          <input type="checkbox" checked={showAll} onChange={(e) => setShowAll(e.target.checked)} /> Show finished
        </label>
      }
    >
      <p className="mb-3 text-xs text-muted">
        Seized collateral is sold by Dutch auction: the price starts above the oracle price and falls linearly to a floor.
        Proceeds repay noteholders first, then the liquidation penalty.
      </p>
      {visible.length === 0 ? (
        <Empty>No active liquidation auctions.</Empty>
      ) : (
        <div className="space-y-3">
          {visible.map((x) => (
            <AuctionRow key={x.id.toString()} id={x.id} a={x.a} price={x.price} duration={duration} coll={symOf(x.a.collateral)} stable={stable} />
          ))}
        </div>
      )}
    </Card>
  );
}

function AuctionRow({
  id,
  a,
  price,
  duration,
  coll,
  stable,
}: {
  id: bigint;
  a: Auction;
  price?: bigint;
  duration?: bigint;
  coll?: TokenMeta;
  stable?: TokenMeta;
}) {
  const chainId = useAppChainId();
  const d = useDeployment();
  const clock = useClock();
  const { writeContractAsync } = useWriteContract();
  const [amtStr, setAmtStr] = useState("");
  const [slipStr, setSlipStr] = useState("1");
  const sym = coll?.symbol ?? shortAddr(a.collateral);
  const cd = Number(a.collDecimals);
  const sd = stable?.decimals ?? 6;
  const end = duration !== undefined ? a.startTime + duration : undefined;
  const atFloor = end !== undefined && clock.now >= end;

  const { data: liveCurrent } = useReadContract({
    address: d?.Liquidator,
    abi: LiquidatorAbi,
    functionName: "currentPrice",
    args: [id],
    chainId,
    query: { enabled: !!d && a.active, refetchInterval: 5_000 },
  });
  const cur = liveCurrent ?? price;

  const owed = a.debtLeft + a.penaltyLeft;
  const slipBps = percentToBps(slipStr) ?? 0;
  const maxPrice = cur !== undefined ? mulDiv(cur, BPS + BigInt(slipBps), BPS) : undefined;
  const want = parseAmount(amtStr, cd);
  // the contract caps the take at what is needed to cover debt + penalty at the execution price
  const needed = cur !== undefined && cur > 0n ? collateralFor(owed, cd, cur, sd) : a.collateralLeft;
  const maxTake = a.collateralLeft < needed ? a.collateralLeft : needed;
  const take = want !== null && want !== undefined ? (want < maxTake ? want : maxTake) : 0n;
  const maxCost = maxPrice !== undefined && take > 0n ? collateralValue(take, cd, maxPrice, sd, true) + 1n : 0n;
  const approveAmt = maxCost > owed ? owed : maxCost;

  return (
    <div className="rounded-lg border border-line bg-panel2/50 p-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-sm">Auction #{id.toString()}</span>
        <span className="text-xs text-muted">repo #{a.repoId.toString()}</span>
        <Badge tone={a.active ? (atFloor ? "warn" : "info") : "muted"}>{a.active ? (atFloor ? "at floor" : "live") : "finished"}</Badge>
      </div>
      <div className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-4">
        <div>
          <span className="text-muted">Collateral left </span>
          {fmtAmount(a.collateralLeft, cd)} {sym}
        </div>
        <div>
          <span className="text-muted">Price now </span>
          {fmtUsdE18(cur)}
        </div>
        <div>
          <span className="text-muted">Floor </span>
          {fmtUsdE18(a.floorPrice)}
        </div>
        <div>
          <span className="text-muted">Owed </span>
          {fmtAmount(owed, sd, 2)} {stable?.symbol}
        </div>
        {a.active && end !== undefined && !atFloor && (
          <div>
            <span className="text-muted">Floor in </span>
            <Countdown to={end} now={clock.now} />
          </div>
        )}
      </div>
      {a.active && d && stable && (
        <div className="mt-3 grid gap-3 sm:grid-cols-3">
          <Field label={`Collateral to buy (max ${fmtAmount(maxTake, cd)})`}>
            <div className="flex gap-2">
              <input className="input" inputMode="decimal" value={amtStr} onChange={(e) => setAmtStr(e.target.value)} placeholder="0.0" />
              <button type="button" className="btn-secondary shrink-0 px-3 text-xs" onClick={() => setAmtStr(fmtAmount(maxTake, cd, cd).replace(/,/g, ""))}>
                Max
              </button>
            </div>
          </Field>
          <Field label="Max slippage (%)" hint={`Max price ${fmtUsdE18(maxPrice)}`}>
            <input className="input" inputMode="decimal" value={slipStr} onChange={(e) => setSlipStr(e.target.value)} />
          </Field>
          <div className="flex flex-col justify-end gap-2">
            <span className="text-xs text-muted">
              Cost ≤ {fmtAmount(approveAmt, sd, 2)} {stable.symbol}
            </span>
            <TxButton
              small
              label="Buy"
              approval={approveAmt > 0n ? { token: stable.address, spender: d.Liquidator, amount: approveAmt, symbol: stable.symbol, decimals: sd } : undefined}
              disabled={take === 0n || maxPrice === undefined}
              disabledReason={take === 0n ? "Enter an amount" : undefined}
              action={() =>
                writeContractAsync({
                  address: d.Liquidator,
                  abi: LiquidatorAbi,
                  functionName: "buy",
                  args: [id, take, maxPrice!, clock.now + 300n],
                  chainId,
                })
              }
            />
          </div>
          {atFloor && (
            <div className="sm:col-span-3">
              <TxButton
                small
                variant="secondary"
                label="Restart at fresh oracle price"
                requireRiskAck={false}
                action={() => writeContractAsync({ address: d.Liquidator, abi: LiquidatorAbi, functionName: "restart", args: [id], chainId })}
              />
            </div>
          )}
        </div>
      )}
    </div>
  );
}

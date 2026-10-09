"use client";

import { useMemo, useRef, useState } from "react";
import { useAccount, usePublicClient, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import { parseEventLogs } from "viem";
import type { Address, Hex, TransactionReceipt } from "viem";
import { AuctionHouseAbi, ComplianceRegistryAbi, MarketClockAbi, OracleAdapterAbi } from "@/abi";
import { TxButton } from "@/components/TxButton";
import { Card, Countdown, Field, Notice, PhaseBadge } from "@/components/ui";
import { useTokenBalance } from "@/hooks/useBalance";
import { useBooks, useClock, useStable } from "@/hooks/useProtocol";
import { commitmentHash, randomSalt, SIDE_BORROW, SIDE_LEND } from "@/lib/commitment";
import type { Side } from "@/lib/commitment";
import { errMsg, fmtAmount, fmtBps, fmtDuration, fmtUsdE18, parseAmount } from "@/lib/format";
import { auctionFee, maxBorrowable, percentToBps, PHASE, requiredCollateral } from "@/lib/math";
import { attachOrderId, downloadJson, exportBackup, saveOrder } from "@/lib/orderStore";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

export function OrderForm() {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { address } = useAccount();
  const clock = useClock();
  const stable = useStable();
  const { books, params, collaterals } = useBooks();
  const publicClient = usePublicClient({ chainId });
  const { writeContractAsync } = useWriteContract();

  const [side, setSide] = useState<Side>(SIDE_LEND);
  const [collChoice, setCollChoice] = useState<string>("");
  const [termChoice, setTermChoice] = useState<number | null>(null);
  const [amountStr, setAmountStr] = useState("");
  const [rateStr, setRateStr] = useState("");
  const [collStr, setCollStr] = useState("");
  const [rollover, setRollover] = useState(false);
  const [lastOrder, setLastOrder] = useState<{ id: bigint; epoch: bigint } | null>(null);
  const [prepError, setPrepError] = useState<string | null>(null);
  const pending = useRef<{ commitment: Hex; epoch: bigint } | null>(null);

  const collateral = (collChoice || collaterals[0]?.address || "") as Address | "";
  const terms = useMemo(
    () => books.filter((b) => b.collateral === collateral).sort((a, b) => a.duration - b.duration),
    [books, collateral],
  );
  const book = terms.find((b) => b.termId === termChoice) ?? terms[0];

  const amount = parseAmount(amountStr, stable?.decimals);
  const rateBps = percentToBps(rateStr);
  const collAmount = side === SIDE_BORROW ? parseAmount(collStr, book?.collDecimals) : 0n;

  const { data: priceData, error: priceError } = useReadContract({
    address: d?.OracleAdapter,
    abi: OracleAdapterAbi,
    functionName: "getPrice",
    args: [book?.collateral as Address],
    chainId,
    query: { enabled: !!d && !!book, refetchInterval: 30_000, retry: false },
  });
  const priceE18 = priceData?.[0];

  const { data: extra } = useReadContracts({
    contracts: [
      { address: d?.AuctionHouse as Address, abi: AuctionHouseAbi, functionName: "paused", chainId },
      { address: d?.ComplianceRegistry as Address, abi: ComplianceRegistryAbi, functionName: "isAllowed", args: [address as Address], chainId },
      {
        address: d?.AuctionHouse as Address,
        abi: AuctionHouseAbi,
        functionName: "committedCollateral",
        args: [book?.id ?? 0, clock.epoch ?? 0n],
        chainId,
      },
      { address: d?.AuctionHouse as Address, abi: AuctionHouseAbi, functionName: "bookOrders", args: [book?.id ?? 0, clock.epoch ?? 0n], chainId },
    ],
    query: { enabled: !!d && !!book && clock.epoch !== undefined, refetchInterval: 15_000 },
  });
  const paused = extra?.[0].status === "success" ? extra[0].result : false;
  const allowed = !address || extra?.[1].status !== "success" ? true : extra[1].result;
  const committedColl = extra?.[2].status === "success" ? extra[2].result : 0n;
  const sideCount =
    extra?.[3].status === "success" ? (side === SIDE_LEND ? extra[3].result[0].length : extra[3].result[1].length) : 0;

  const stableBal = useTokenBalance(stable?.address);
  const collBal = useTokenBalance(book?.collateral);

  const sd = stable?.decimals ?? 6;
  const required =
    side === SIDE_BORROW && book && priceE18 && amount && amount > 0n
      ? requiredCollateral(amount, book.collDecimals, priceE18, sd, book.initialHaircutBps)
      : undefined;
  const maxBorrow =
    side === SIDE_BORROW && book && priceE18 && collAmount && collAmount > 0n
      ? maxBorrowable(collAmount, book.collDecimals, priceE18, sd, book.initialHaircutBps)
      : undefined;
  const fee = side === SIDE_BORROW && book && params && amount ? auctionFee(amount, params.auctionFeeBpsPerYear, book.duration) : undefined;

  const inCommit = clock.phase === PHASE.Commit;
  const commitLeft = clock.times ? clock.times.commitEnd - clock.now : 0n;
  const nextCommit = clock.params && clock.times ? clock.times.start + clock.params.interval : undefined;

  const problems: string[] = [];
  if (!book) problems.push("Select a book.");
  else if (!book.active) problems.push("This book is currently disabled.");
  if (!inCommit) problems.push("Orders can only be committed during the Commit phase.");
  if (paused) problems.push("The auction house is paused by the guardian.");
  if (!allowed) problems.push("Your address is not on the compliance allowlist.");
  if (amount === null || amount === 0n) problems.push("Enter an amount.");
  else if (params && amount < params.minOrderSize)
    problems.push(`Minimum order is ${fmtAmount(params.minOrderSize, sd)} ${stable?.symbol ?? ""}.`);
  if (rateBps === null || rateBps === 0) problems.push("Enter a rate (e.g. 5.25).");
  else if (params && rateBps > params.maxRateBps) problems.push(`Max rate is ${fmtBps(params.maxRateBps)}.`);
  if (params && sideCount >= params.maxOrdersPerSide) problems.push("This side of the book is full for this auction.");
  if (side === SIDE_LEND && amount && stableBal !== undefined && stableBal < amount)
    problems.push(`Insufficient ${stable?.symbol ?? "stablecoin"} balance.`);
  if (side === SIDE_BORROW) {
    if (collAmount === null || collAmount === 0n) problems.push("Enter a collateral amount.");
    else {
      if (collBal !== undefined && collBal < collAmount) problems.push(`Insufficient ${book?.collSymbol} balance.`);
      if (required !== undefined && collAmount < required)
        problems.push("Collateral is below the initial margin at the current oracle price; the bid would be excluded at clearing.");
      if (book && book.maxCollateralPerAuction > 0n && committedColl + collAmount > book.maxCollateralPerAuction)
        problems.push("This exceeds the per-auction collateral cap for the book.");
    }
    if (priceError) problems.push("Oracle price unavailable (stale or halted); borrowing is blocked.");
  }

  async function prepare() {
    setPrepError(null);
    if (!address || !book || !amount || !rateBps || !publicClient || !d) throw new Error("Form incomplete");
    // Read the epoch from the contract (no secret involved) so the commitment matches what commit*() records.
    const epoch = await publicClient.readContract({ address: d.MarketClock, abi: MarketClockAbi, functionName: "currentEpoch" });
    const phase = await publicClient.readContract({ address: d.MarketClock, abi: MarketClockAbi, functionName: "phase", args: [epoch] });
    if (phase !== PHASE.Commit) throw new Error("The commit window has closed.");
    const salt = randomSalt();
    const coll = side === SIDE_BORROW ? (collAmount ?? 0n) : 0n;
    // computed locally: never send the rate to an RPC before the reveal
    const commitment = commitmentHash({ owner: address, bookId: book.id, epoch, side, amount, collateral: coll, rateBps, salt });
    saveOrder({
      chainId,
      account: address,
      orderId: null,
      bookId: book.id,
      epoch: epoch.toString(),
      side,
      amount: amount.toString(),
      collateral: coll.toString(),
      rateBps,
      salt,
      commitment,
      createdAt: Math.floor(Date.now() / 1000),
    });
    pending.current = { commitment, epoch };
  }

  async function send(): Promise<Hex> {
    const p = pending.current;
    if (!p || !book || !amount) throw new Error("Order not prepared");
    if (side === SIDE_LEND) {
      return writeContractAsync({
        address: d!.AuctionHouse,
        abi: AuctionHouseAbi,
        functionName: "commitLend",
        args: [book.id, amount, p.commitment, rollover],
        chainId,
      });
    }
    return writeContractAsync({
      address: d!.AuctionHouse,
      abi: AuctionHouseAbi,
      functionName: "commitBorrow",
      args: [book.id, amount, collAmount ?? 0n, p.commitment, rollover],
      chainId,
    });
  }

  function onConfirmed(receipt: TransactionReceipt) {
    const logs = parseEventLogs({ abi: AuctionHouseAbi, eventName: "OrderCommitted", logs: receipt.logs });
    const p = pending.current;
    const log = logs.find((l) => l.args.owner.toLowerCase() === address?.toLowerCase());
    if (log && p) {
      attachOrderId(p.commitment, log.args.orderId, receipt.transactionHash);
      setLastOrder({ id: log.args.orderId, epoch: log.args.epoch });
    }
    pending.current = null;
    setRateStr("");
  }

  const approval =
    d && book && stable
      ? side === SIDE_LEND
        ? { token: stable.address, spender: d.AuctionHouse, amount: amount ?? 0n, symbol: stable.symbol, decimals: stable.decimals }
        : { token: book.collateral, spender: d.AuctionHouse, amount: collAmount ?? 0n, symbol: book.collSymbol, decimals: book.collDecimals }
      : undefined;

  return (
    <Card
      title="New order"
      actions={
        <span className="flex items-center gap-2 text-xs">
          <PhaseBadge phase={clock.phase} />
          {inCommit ? <Countdown to={clock.times?.commitEnd} now={clock.now} label="closes in" /> : <Countdown to={nextCommit} now={clock.now} label="next commit in" />}
        </span>
      }
    >
      <div className="space-y-4">
        <div className="seg w-full" role="group" aria-label="Side">
          <button type="button" className="flex-1" aria-pressed={side === SIDE_LEND} onClick={() => setSide(SIDE_LEND)}>
            Lend
          </button>
          <button type="button" className="flex-1" aria-pressed={side === SIDE_BORROW} onClick={() => setSide(SIDE_BORROW)}>
            Borrow
          </button>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <Field label="Collateral">
            <select className="input" value={collateral} onChange={(e) => setCollChoice(e.target.value)}>
              {collaterals.map((c) => (
                <option key={c.address} value={c.address}>
                  {c.symbol}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Term">
            <select className="input" value={book?.termId ?? ""} onChange={(e) => setTermChoice(Number(e.target.value))}>
              {terms.map((b) => (
                <option key={b.id} value={b.termId} disabled={!b.active}>
                  {b.termLabel} ({fmtDuration(b.duration)}){b.active ? "" : " - disabled"}
                </option>
              ))}
            </select>
          </Field>
        </div>

        <Field
          label={side === SIDE_LEND ? `Amount to lend (${stable?.symbol ?? ""})` : `Amount to borrow (${stable?.symbol ?? ""})`}
          hint={
            side === SIDE_LEND
              ? `Balance: ${fmtAmount(stableBal, stable?.decimals, 2)} ${stable?.symbol ?? ""}`
              : fee !== undefined
                ? `Auction fee ≈ ${fmtAmount(fee, sd, 2)}; you receive ≈ ${fmtAmount((amount ?? 0n) - fee, sd, 2)} ${stable?.symbol ?? ""} if fully filled.`
                : undefined
          }
        >
          <input className="input" inputMode="decimal" placeholder="0.00" value={amountStr} onChange={(e) => setAmountStr(e.target.value)} />
        </Field>

        <Field
          label={side === SIDE_LEND ? "Minimum rate (% per year)" : "Maximum rate (% per year)"}
          hint={`Sealed until you reveal. Max ${params ? fmtBps(params.maxRateBps) : "-"}.`}
        >
          <input className="input" inputMode="decimal" placeholder="5.00" value={rateStr} onChange={(e) => setRateStr(e.target.value)} />
        </Field>

        {side === SIDE_BORROW && book && (
          <div className="space-y-2">
            <Field label={`Collateral to escrow (${book.collSymbol})`} hint={`Balance: ${fmtAmount(collBal, book.collDecimals)} ${book.collSymbol}`}>
              <div className="flex gap-2">
                <input className="input" inputMode="decimal" placeholder="0.0" value={collStr} onChange={(e) => setCollStr(e.target.value)} />
                {required !== undefined && (
                  <button
                    type="button"
                    className="btn-secondary shrink-0 px-3 text-xs"
                    title="Required collateral plus a 5% buffer"
                    onClick={() => setCollStr(fmtAmount((required * 105n) / 100n, book.collDecimals, book.collDecimals).replace(/,/g, ""))}
                  >
                    Min +5%
                  </button>
                )}
              </div>
            </Field>
            <div className="rounded-lg bg-panel2 p-3 text-xs text-muted">
              <div className="flex justify-between">
                <span>Oracle price</span>
                <span className="text-fg">{priceError ? <span className="text-bad">unavailable</span> : fmtUsdE18(priceE18)}</span>
              </div>
              <div className="flex justify-between">
                <span>Initial haircut</span>
                <span className="text-fg">{fmtBps(book.initialHaircutBps)}</span>
              </div>
              <div className="flex justify-between">
                <span>Required collateral for this loan</span>
                <span className="text-fg">
                  {required !== undefined ? `${fmtAmount(required, book.collDecimals)} ${book.collSymbol}` : "-"}
                </span>
              </div>
              <div className="flex justify-between">
                <span>Max borrowable with this collateral</span>
                <span className="text-fg">
                  {maxBorrow !== undefined ? `${fmtAmount(maxBorrow, sd, 2)} ${stable?.symbol ?? ""}` : "-"}
                </span>
              </div>
              <p className="mt-2">
                The margin check is re-run at the clearing price feed; keep a buffer. Maintenance haircut{" "}
                {fmtBps(book.maintenanceHaircutBps)}, liquidation penalty {fmtBps(book.liquidationPenaltyBps)}.
              </p>
            </div>
          </div>
        )}

        <label className="flex items-start gap-2 text-sm">
          <input type="checkbox" className="mt-0.5 h-4 w-4" checked={rollover} onChange={(e) => setRollover(e.target.checked)} />
          <span>
            Roll any unfilled remainder into the next auction at the same rate
            <span className="block text-xs text-muted">Rolled orders are already revealed; you can cancel them during their commit window.</span>
          </span>
        </label>

        {!inCommit && clock.phase !== undefined && (
          <Notice>
            Commits are only accepted during the Commit phase. The next commit window opens in{" "}
            <Countdown to={nextCommit} now={clock.now} />.
          </Notice>
        )}
        {inCommit && commitLeft > 0n && commitLeft < 60n && (
          <Notice tone="warn">Less than a minute left in this commit window. A late transaction will revert.</Notice>
        )}
        {prepError && <Notice tone="bad">{prepError}</Notice>}

        <TxButton
          label={side === SIDE_LEND ? "Commit lend order" : "Commit borrow order"}
          className="w-full"
          approval={approval}
          disabled={problems.length > 0}
          disabledReason={problems[0]}
          beforeAction={async () => {
            try {
              await prepare();
            } catch (e) {
              setPrepError(errMsg(e));
              throw e;
            }
          }}
          action={send}
          onConfirmed={onConfirmed}
        />
        <p className="text-xs text-muted">
          Your rate and a random salt are stored in this browser before the transaction is sent. You must reveal during
          the Reveal phase, or {params ? fmtBps(params.noRevealPenaltyBps) : "1%"} of the escrow is forfeited.
        </p>

        {lastOrder && address && (
          <Notice tone="warn">
            Order #{lastOrder.id.toString()} committed for epoch {lastOrder.epoch.toString()}. Download a backup of your
            order secrets now; clearing browser data would make the order impossible to reveal.
            <div className="mt-2">
              <button
                type="button"
                className="btn-secondary px-3 py-1.5 text-xs"
                onClick={() =>
                  downloadJson(`overnight-desk-orders-${chainId}-${address.slice(2, 8)}.json`, exportBackup({ chainId, account: address }))
                }
              >
                Download backup (JSON)
              </button>
            </div>
          </Notice>
        )}
      </div>
    </Card>
  );
}

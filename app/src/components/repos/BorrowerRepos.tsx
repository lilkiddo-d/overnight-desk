"use client";

import { useMemo, useState } from "react";
import { useAccount, useReadContract, useReadContracts, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { MarginEngineAbi, OracleAdapterAbi, RepoLockerAbi } from "@/abi";
import { TxButton } from "@/components/TxButton";
import { Badge, Card, Countdown, Empty, Field } from "@/components/ui";
import { useBooks, useClock, useStable } from "@/hooks/useProtocol";
import type { BookInfo, RegistryParams, TokenMeta } from "@/hooks/useProtocol";
import { fmtAmount, fmtBps, fmtTime, fmtUsdE18, parseAmount } from "@/lib/format";
import { interest, percentToBps, repayWithBuffer, requiredCollateral } from "@/lib/math";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

const STATUS = ["None", "Active", "Margin call", "Liquidating", "Closed"] as const;
const MAX_ROWS = 50;

type Repo = {
  borrower: Address;
  bookId: number;
  status: number;
  autoRoll: boolean;
  rolling: boolean;
  rateBps: number;
  autoRollMaxRateBps: number;
  start: bigint;
  maturity: bigint;
  marginCallDeadline: bigint;
  collateral: Address;
  collateralAmount: bigint;
  principal: bigint;
  seriesId: bigint;
};
type Health = { debt: bigint; value: bigint; maintLimit: bigint; critLimit: bigint };

export function BorrowerRepos() {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { address } = useAccount();
  const stable = useStable();
  const { books, params } = useBooks();
  const [showClosed, setShowClosed] = useState(false);

  const { data: ids } = useReadContract({
    address: d?.RepoLocker,
    abi: RepoLockerAbi,
    functionName: "reposOf",
    args: [address as Address],
    chainId,
    query: { enabled: !!d && !!address, refetchInterval: 15_000 },
  });
  const recent = useMemo(() => [...(ids ?? [])].reverse().slice(0, MAX_ROWS), [ids]);
  const { data } = useReadContracts({
    contracts: recent.flatMap(
      (id) =>
        [
          { address: d?.RepoLocker as Address, abi: RepoLockerAbi, functionName: "getRepo", args: [id], chainId },
          { address: d?.RepoLocker as Address, abi: RepoLockerAbi, functionName: "debtOf", args: [id], chainId },
          { address: d?.MarginEngine as Address, abi: MarginEngineAbi, functionName: "health", args: [id], chainId },
        ] as const,
    ),
    query: { enabled: !!d && recent.length > 0, refetchInterval: 15_000 },
  });

  const repos = recent.flatMap((id, i) => {
    const r = data?.[i * 3];
    const debt = data?.[i * 3 + 1];
    const h = data?.[i * 3 + 2];
    if (r?.status !== "success") return [];
    const repo = r.result as unknown as Repo;
    const health =
      h?.status === "success"
        ? (() => {
            const [hd, v, m, c] = h.result as readonly [bigint, bigint, bigint, bigint];
            return { debt: hd, value: v, maintLimit: m, critLimit: c };
          })()
        : undefined;
    return [{ id, repo, debt: debt?.status === "success" ? (debt.result as bigint) : undefined, health }];
  });
  const bookById = useMemo(() => new Map(books.map((b) => [b.id, b])), [books]);
  const visible = repos.filter((r) => showClosed || (r.repo.status !== 4 && r.repo.status !== 0));

  return (
    <Card
      title="My repos (borrower)"
      actions={
        <label className="flex items-center gap-2 text-xs text-muted">
          <input type="checkbox" checked={showClosed} onChange={(e) => setShowClosed(e.target.checked)} /> Show closed
        </label>
      }
    >
      {!address ? (
        <Empty>Connect a wallet to see your repos.</Empty>
      ) : visible.length === 0 ? (
        <Empty>No open repos.</Empty>
      ) : (
        <div className="space-y-3">
          {visible.map((r) => (
            <RepoCard
              key={r.id.toString()}
              id={r.id}
              repo={r.repo}
              debt={r.debt}
              health={r.health}
              book={bookById.get(r.repo.bookId)}
              stable={stable}
              params={params}
            />
          ))}
        </div>
      )}
    </Card>
  );
}

function healthView(h: Health | undefined, status: number) {
  if (status === 3) return { tone: "bad" as const, label: "Liquidating", ratio: 1.2 };
  if (status === 2) return { tone: "bad" as const, label: "Margin call", ratio: h && h.maintLimit > 0n ? Number(h.debt) / Number(h.maintLimit) : 1 };
  if (!h) return { tone: "muted" as const, label: "Price unavailable", ratio: 0 };
  const ratio = h.maintLimit > 0n ? Number(h.debt) / Number(h.maintLimit) : 0;
  if (h.debt > h.critLimit) return { tone: "bad" as const, label: "Liquidatable", ratio };
  if (h.debt > h.maintLimit) return { tone: "bad" as const, label: "Below maintenance", ratio };
  if (ratio > 0.9) return { tone: "warn" as const, label: "Near margin call", ratio };
  return { tone: "good" as const, label: "Healthy", ratio };
}

function RepoCard({
  id,
  repo,
  debt,
  health,
  book,
  stable,
  params,
}: {
  id: bigint;
  repo: Repo;
  debt?: bigint;
  health?: Health;
  book?: BookInfo;
  stable?: TokenMeta;
  params?: RegistryParams;
}) {
  const chainId = useAppChainId();
  const d = useDeployment();
  const clock = useClock();
  const { writeContractAsync } = useWriteContract();
  const [tab, setTab] = useState<"repay" | "add" | "withdraw" | "roll" | null>(null);
  const [repayStr, setRepayStr] = useState("");
  const [addStr, setAddStr] = useState("");
  const [wdStr, setWdStr] = useState("");
  const [rollEnabled, setRollEnabled] = useState(repo.autoRoll);
  const [rollRate, setRollRate] = useState(repo.autoRollMaxRateBps ? (repo.autoRollMaxRateBps / 100).toFixed(2) : "");

  const { data: priceData } = useReadContract({
    address: d?.OracleAdapter,
    abi: OracleAdapterAbi,
    functionName: "getPrice",
    args: [repo.collateral],
    chainId,
    query: { enabled: !!d && tab === "withdraw", retry: false },
  });

  const sd = stable?.decimals ?? 6;
  const cd = book?.collDecimals ?? 18;
  const sym = book?.collSymbol ?? "collateral";
  const open = repo.status === 1 || repo.status === 2;
  const hv = healthView(health, repo.status);
  const pct = Math.min(1, hv.ratio / 1.2) * 100;
  const barColor = hv.tone === "good" ? "bg-emerald-400" : hv.tone === "warn" ? "bg-amber-400" : hv.tone === "bad" ? "bg-red-400" : "bg-zinc-500";
  const graceEnd = params ? repo.maturity + BigInt(params.maturityGracePeriod) : undefined;
  const matured = clock.now >= repo.maturity;

  const fullRepay = debt !== undefined ? repayWithBuffer(debt, repo.principal, repo.rateBps) : undefined;
  const partial = parseAmount(repayStr, sd);
  const addAmt = parseAmount(addStr, cd);
  const wdAmt = parseAmount(wdStr, cd);
  const priceE18 = priceData?.[0];
  const needAfter =
    priceE18 && debt !== undefined && book
      ? requiredCollateral(debt + interest(repo.principal, repo.rateBps, 3600), cd, priceE18, sd, book.initialHaircutBps)
      : undefined;
  const maxWithdraw = needAfter !== undefined ? (repo.collateralAmount > needAfter ? repo.collateralAmount - needAfter : 0n) : undefined;
  const rollBps = percentToBps(rollRate);

  return (
    <div className="rounded-lg border border-line bg-panel2/50 p-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-sm">Repo #{id.toString()}</span>
        <span className="text-sm">
          {book ? `${book.collSymbol} · ${book.termLabel}` : `book ${repo.bookId}`}
        </span>
        <Badge tone={repo.status === 4 ? "muted" : hv.tone}>{repo.status === 1 ? hv.label : STATUS[repo.status]}</Badge>
        {repo.autoRoll && <Badge tone="info">auto-roll ≤ {fmtBps(repo.autoRollMaxRateBps)}</Badge>}
        {repo.rolling && <Badge tone="info">rolling</Badge>}
      </div>

      <div className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-4">
        <div>
          <span className="text-muted">Debt </span>
          {fmtAmount(debt, sd, 2)} {stable?.symbol}
        </div>
        <div>
          <span className="text-muted">Rate </span>
          {fmtBps(repo.rateBps)}
        </div>
        <div>
          <span className="text-muted">Collateral </span>
          {fmtAmount(repo.collateralAmount, cd)} {sym}
        </div>
        <div>
          <span className="text-muted">Value </span>
          {health ? `${fmtAmount(health.value, sd, 2)} ${stable?.symbol ?? ""}` : "-"}
        </div>
        <div>
          <span className="text-muted">Maturity </span>
          {fmtTime(repo.maturity)}
        </div>
        <div>
          <span className="text-muted">{matured ? "Liquidatable after " : "Matures in "}</span>
          {matured ? <Countdown to={graceEnd} now={clock.now} /> : <Countdown to={repo.maturity} now={clock.now} />}
        </div>
        {repo.status === 2 && (
          <div className="col-span-2 font-semibold text-bad">
            Cure by <Countdown to={repo.marginCallDeadline} now={clock.now} /> (repay or add collateral)
          </div>
        )}
      </div>

      {open && health && (
        <div className="mt-3">
          <div className="flex justify-between text-[11px] text-muted">
            <span>Debt / maintenance limit: {(hv.ratio * 100).toFixed(1)}%</span>
            <span>
              Margin call above {fmtAmount(health.maintLimit, sd, 2)} · liquidation above {fmtAmount(health.critLimit, sd, 2)}
            </span>
          </div>
          <div className="relative mt-1 h-2 overflow-hidden rounded-full bg-zinc-800" role="meter" aria-valuenow={Math.round(hv.ratio * 100)} aria-valuemin={0} aria-valuemax={120}>
            <div className={`h-full ${barColor}`} style={{ width: `${pct}%` }} />
            <div className="absolute inset-y-0 w-px bg-white/60" style={{ left: `${(1 / 1.2) * 100}%` }} title="Maintenance limit" />
          </div>
        </div>
      )}

      {open && (
        <>
          <div className="mt-3 flex flex-wrap gap-2">
            {(["repay", "add", "withdraw", "roll"] as const).map((k) => (
              <button
                key={k}
                type="button"
                className={`btn-secondary px-3 py-1.5 text-xs ${tab === k ? "border-accent" : ""}`}
                onClick={() => setTab(tab === k ? null : k)}
              >
                {k === "repay" ? "Repay" : k === "add" ? "Add collateral" : k === "withdraw" ? "Withdraw excess" : "Auto-roll"}
              </button>
            ))}
          </div>

          {tab === "repay" && d && stable && (
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <div className="space-y-2">
                <p className="text-xs text-muted">
                  Full repayment closes the repo and returns all collateral. Approves debt plus a small interest buffer; only
                  the actual debt is transferred.
                </p>
                <TxButton
                  small
                  label="Repay in full"
                  requireRiskAck={false}
                  approval={fullRepay ? { token: stable.address, spender: d.RepoLocker, amount: fullRepay, symbol: stable.symbol, decimals: sd } : undefined}
                  disabled={!fullRepay}
                  action={() => writeContractAsync({ address: d.RepoLocker, abi: RepoLockerAbi, functionName: "repay", args: [id, fullRepay!], chainId })}
                />
              </div>
              <div className="space-y-2">
                <Field label={`Partial amount (${stable.symbol})`}>
                  <input className="input" inputMode="decimal" value={repayStr} onChange={(e) => setRepayStr(e.target.value)} placeholder="0.00" />
                </Field>
                <TxButton
                  small
                  variant="secondary"
                  label="Repay"
                  requireRiskAck={false}
                  approval={partial ? { token: stable.address, spender: d.RepoLocker, amount: partial, symbol: stable.symbol, decimals: sd } : undefined}
                  disabled={!partial}
                  action={() => writeContractAsync({ address: d.RepoLocker, abi: RepoLockerAbi, functionName: "repay", args: [id, partial!], chainId })}
                />
              </div>
            </div>
          )}

          {tab === "add" && d && (
            <div className="mt-3 max-w-sm space-y-2">
              <Field label={`Amount (${sym})`}>
                <input className="input" inputMode="decimal" value={addStr} onChange={(e) => setAddStr(e.target.value)} placeholder="0.0" />
              </Field>
              <TxButton
                small
                label="Add collateral"
                requireRiskAck={false}
                approval={addAmt ? { token: repo.collateral, spender: d.RepoLocker, amount: addAmt, symbol: sym, decimals: cd } : undefined}
                disabled={!addAmt}
                action={() => writeContractAsync({ address: d.RepoLocker, abi: RepoLockerAbi, functionName: "addCollateral", args: [id, addAmt!], chainId })}
              />
            </div>
          )}

          {tab === "withdraw" && d && (
            <div className="mt-3 max-w-sm space-y-2">
              <Field
                label={`Amount (${sym})`}
                hint={
                  repo.status !== 1
                    ? "Withdrawals are only possible while the repo is Active."
                    : maxWithdraw !== undefined
                      ? `≈ ${fmtAmount(maxWithdraw, cd)} ${sym} above the initial margin (price ${fmtUsdE18(priceE18)}).`
                      : "Reading oracle price…"
                }
              >
                <div className="flex gap-2">
                  <input className="input" inputMode="decimal" value={wdStr} onChange={(e) => setWdStr(e.target.value)} placeholder="0.0" />
                  {maxWithdraw !== undefined && maxWithdraw > 0n && (
                    <button type="button" className="btn-secondary shrink-0 px-3 text-xs" onClick={() => setWdStr(fmtAmount(maxWithdraw, cd, cd).replace(/,/g, ""))}>
                      Max
                    </button>
                  )}
                </div>
              </Field>
              <TxButton
                small
                variant="secondary"
                label="Withdraw"
                requireRiskAck={false}
                disabled={!wdAmt || repo.status !== 1 || repo.rolling}
                disabledReason={repo.rolling ? "Repo is being rolled in the current auction." : undefined}
                action={() => writeContractAsync({ address: d.RepoLocker, abi: RepoLockerAbi, functionName: "withdrawCollateral", args: [id, wdAmt!], chainId })}
              />
            </div>
          )}

          {tab === "roll" && d && (
            <div className="mt-3 max-w-sm space-y-2">
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" checked={rollEnabled} onChange={(e) => setRollEnabled(e.target.checked)} /> Roll into the
                next auction at maturity
              </label>
              <Field label="Maximum rate (% per year)" hint={params ? `Up to ${fmtBps(params.maxRateBps)}.` : undefined}>
                <input className="input" inputMode="decimal" value={rollRate} onChange={(e) => setRollRate(e.target.value)} placeholder="8.00" />
              </Field>
              <p className="text-xs text-muted">
                A keeper submits your repo as a price-taking bid in the auction before maturity. If it does not fill, you
                must repay by maturity plus the grace period.
              </p>
              <TxButton
                small
                label="Save auto-roll"
                disabled={rollEnabled && (rollBps === null || rollBps === 0 || (params ? rollBps > params.maxRateBps : false))}
                disabledReason="Enter a valid maximum rate"
                action={() =>
                  writeContractAsync({
                    address: d.RepoLocker,
                    abi: RepoLockerAbi,
                    functionName: "setAutoRoll",
                    args: [id, rollEnabled, rollEnabled ? (rollBps ?? 0) : 0],
                    chainId,
                  })
                }
              />
            </div>
          )}
        </>
      )}
    </div>
  );
}

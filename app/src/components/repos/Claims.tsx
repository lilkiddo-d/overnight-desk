"use client";

import { useMemo } from "react";
import { useAccount, useReadContracts, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { LiquidatorAbi, RepoLockerAbi } from "@/abi";
import { TxButton } from "@/components/TxButton";
import { Card, Empty } from "@/components/ui";
import { useBooks, useStable } from "@/hooks/useProtocol";
import { fmtAmount } from "@/lib/format";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

/** Pull balances held for the user: RepoLocker (roll surpluses, returned collateral) and Liquidator (leftover collateral). */
export function Claims() {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { address } = useAccount();
  const stable = useStable();
  const { collaterals } = useBooks();
  const { writeContractAsync } = useWriteContract();
  const tokens = useMemo(() => (stable ? [stable, ...collaterals] : collaterals), [stable, collaterals]);

  const { data } = useReadContracts({
    contracts: tokens.flatMap(
      (t) =>
        [
          { address: d?.RepoLocker as Address, abi: RepoLockerAbi, functionName: "claimable", args: [address as Address, t.address], chainId },
          { address: d?.Liquidator as Address, abi: LiquidatorAbi, functionName: "claimable", args: [address as Address, t.address], chainId },
        ] as const,
    ),
    query: { enabled: !!d && !!address && tokens.length > 0, refetchInterval: 20_000 },
  });

  const rows = tokens.flatMap((t, i) => {
    const a = data?.[i * 2];
    const b = data?.[i * 2 + 1];
    const locker = a?.status === "success" ? (a.result as bigint) : 0n;
    const liq = b?.status === "success" ? (b.result as bigint) : 0n;
    const out: { key: string; token: typeof t; amount: bigint; source: "RepoLocker" | "Liquidator" }[] = [];
    if (locker > 0n) out.push({ key: `l-${t.address}`, token: t, amount: locker, source: "RepoLocker" });
    if (liq > 0n) out.push({ key: `q-${t.address}`, token: t, amount: liq, source: "Liquidator" });
    return out;
  });

  if (!address) return null;
  return (
    <Card title="Claimable balances">
      {rows.length === 0 ? (
        <Empty>Nothing to claim.</Empty>
      ) : (
        <ul className="divide-y divide-line">
          {rows.map((r) => (
            <li key={r.key} className="flex flex-wrap items-center justify-between gap-2 py-2">
              <div className="text-sm">
                {fmtAmount(r.amount, r.token.decimals)} {r.token.symbol}
                <span className="ml-2 text-xs text-muted">from {r.source === "RepoLocker" ? "repo settlement" : "liquidation"}</span>
              </div>
              <TxButton
                small
                label="Claim"
                requireRiskAck={false}
                action={() =>
                  r.source === "RepoLocker"
                    ? writeContractAsync({ address: d!.RepoLocker, abi: RepoLockerAbi, functionName: "claim", args: [r.token.address], chainId })
                    : writeContractAsync({ address: d!.Liquidator, abi: LiquidatorAbi, functionName: "claim", args: [r.token.address], chainId })
                }
              />
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

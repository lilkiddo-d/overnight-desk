"use client";

import { useState } from "react";
import { useAccount, useReadContracts, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { ERC20Abi, ProjectTokenHooksAbi } from "@/abi";
import { DeploymentGate } from "@/components/DeploymentGate";
import { TxButton } from "@/components/TxButton";
import { Badge, Card, Countdown, Empty, Field, Stat } from "@/components/ui";
import { PROJECT_TOKEN } from "@/config/env";
import { useTokenBalance } from "@/hooks/useBalance";
import { useClock, useStable } from "@/hooks/useProtocol";
import { useStakingEnabled } from "@/hooks/useStaking";
import { fmtAmount, fmtBps, fmtDuration, parseAmount } from "@/lib/format";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

export default function StakePage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Stake</h1>
        <p className="mt-1 text-sm text-muted">Stake the project token to earn a share of auction fees and a borrower fee discount.</p>
      </div>
      <DeploymentGate>
        <StakeGate />
      </DeploymentGate>
    </div>
  );
}

function StakeGate() {
  const enabled = useStakingEnabled();
  if (!PROJECT_TOKEN || !enabled) return <Empty>Staking is not available.</Empty>;
  return <Staking />;
}

function Staking() {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { address } = useAccount();
  const clock = useClock();
  const stable = useStable();
  const { writeContractAsync } = useWriteContract();
  const [stakeStr, setStakeStr] = useState("");
  const [unstakeStr, setUnstakeStr] = useState("");
  const h = { address: d?.ProjectTokenHooks as Address, abi: ProjectTokenHooksAbi, chainId } as const;

  const { data } = useReadContracts({
    contracts: [
      { ...h, functionName: "projectToken" },
      { ...h, functionName: "tierThreshold" },
      { ...h, functionName: "discountBps" },
      { ...h, functionName: "minStakeAge" },
      { ...h, functionName: "unstakeCooldown" },
      { ...h, functionName: "totalStaked" },
      { ...h, functionName: "stakers", args: [address as Address] },
      { ...h, functionName: "pendingRewards", args: [address as Address] },
      { ...h, functionName: "feeDiscountBps", args: [address as Address] },
    ],
    query: { enabled: !!d, refetchInterval: 15_000 },
  });
  const ok = <T,>(i: number): T | undefined => (data?.[i]?.status === "success" ? (data[i].result as T) : undefined);
  const token = ok<Address>(0);
  const threshold = ok<bigint>(1);
  const discount = ok<number>(2);
  const minAge = ok<number>(3);
  const cooldown = ok<number>(4);
  const total = ok<bigint>(5);
  const staker = ok<readonly [bigint, bigint, bigint, bigint, bigint, bigint]>(6);
  const pending = address ? ok<bigint>(7) : undefined;
  const myDiscount = address ? ok<bigint>(8) : undefined;

  const { data: meta } = useReadContracts({
    contracts: [
      { address: token as Address, abi: ERC20Abi, functionName: "symbol", chainId },
      { address: token as Address, abi: ERC20Abi, functionName: "decimals", chainId },
    ],
    query: { enabled: !!token, staleTime: Infinity },
  });
  const sym = meta?.[0].status === "success" ? String(meta[0].result) : "TOKEN";
  const dec = meta?.[1].status === "success" ? Number(meta[1].result) : 18;
  const bal = useTokenBalance(token);

  const staked = staker?.[0] ?? 0n;
  const stakedSince = staker?.[3] ?? 0n;
  const unstaking = staker?.[4] ?? 0n;
  const readyAt = staker?.[5] ?? 0n;
  const stakeAmt = parseAmount(stakeStr, dec);
  const unstakeAmt = parseAmount(unstakeStr, dec);
  const tierAt = minAge !== undefined && stakedSince > 0n ? stakedSince + BigInt(minAge) : undefined;

  if (!d) return null;
  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <Card title="Overview">
        <div className="grid grid-cols-2 gap-4">
          <Stat label="Total staked" value={`${fmtAmount(total, dec, 2)} ${sym}`} />
          <Stat label="Your stake" value={`${fmtAmount(staked, dec, 2)} ${sym}`} />
          <Stat label="Pending rewards" value={`${fmtAmount(pending, stable?.decimals, 4)} ${stable?.symbol ?? ""}`} />
          <Stat
            label="Your fee discount"
            value={myDiscount !== undefined && myDiscount > 0n ? <Badge tone="good">{fmtBps(myDiscount)}</Badge> : "none"}
          />
        </div>
        <div className="mt-4 rounded-lg bg-panel2 p-3 text-xs text-muted">
          <p>
            Fee tier: stake at least {fmtAmount(threshold, dec, 2)} {sym} for {minAge !== undefined ? fmtDuration(minAge) : "-"} to get{" "}
            {discount !== undefined ? fmtBps(discount) : "-"} off borrower auction fees. Adding to your stake restarts the age.
          </p>
          <p className="mt-1">Unstaking has a {cooldown !== undefined ? fmtDuration(cooldown) : "-"} cooldown.</p>
          {tierAt !== undefined && threshold !== undefined && staked >= threshold && clock.now < tierAt && (
            <p className="mt-1">
              Discount active in <Countdown to={tierAt} now={clock.now} />.
            </p>
          )}
        </div>
        <div className="mt-4">
          <TxButton
            label="Claim rewards"
            requireRiskAck={false}
            disabled={!pending || pending === 0n}
            action={() => writeContractAsync({ ...h, address: d.ProjectTokenHooks, functionName: "claimRewards" })}
          />
        </div>
      </Card>

      <Card title="Stake / unstake">
        <div className="space-y-4">
          <Field label={`Stake (${sym})`} hint={`Wallet balance: ${fmtAmount(bal, dec, 4)} ${sym}`}>
            <input className="input" inputMode="decimal" value={stakeStr} onChange={(e) => setStakeStr(e.target.value)} placeholder="0.0" />
          </Field>
          <TxButton
            label="Stake"
            approval={token && stakeAmt ? { token, spender: d.ProjectTokenHooks, amount: stakeAmt, symbol: sym, decimals: dec } : undefined}
            disabled={!stakeAmt || (bal !== undefined && stakeAmt > bal)}
            action={() => writeContractAsync({ ...h, address: d.ProjectTokenHooks, functionName: "stake", args: [stakeAmt!] })}
          />
          <hr className="border-line" />
          <Field label={`Request unstake (${sym})`} hint={`Staked: ${fmtAmount(staked, dec, 4)} ${sym}`}>
            <input className="input" inputMode="decimal" value={unstakeStr} onChange={(e) => setUnstakeStr(e.target.value)} placeholder="0.0" />
          </Field>
          <TxButton
            variant="secondary"
            label="Request unstake"
            requireRiskAck={false}
            disabled={!unstakeAmt || unstakeAmt > staked}
            action={() => writeContractAsync({ ...h, address: d.ProjectTokenHooks, functionName: "requestUnstake", args: [unstakeAmt!] })}
          />
          {unstaking > 0n && (
            <div className="rounded-lg bg-panel2 p-3 text-sm">
              <p>
                {fmtAmount(unstaking, dec, 4)} {sym} unstaking.{" "}
                {clock.now < readyAt ? (
                  <>
                    Withdrawable in <Countdown to={readyAt} now={clock.now} />.
                  </>
                ) : (
                  "Ready to withdraw."
                )}
              </p>
              <div className="mt-2">
                <TxButton
                  small
                  label="Withdraw"
                  requireRiskAck={false}
                  disabled={clock.now < readyAt}
                  action={() => writeContractAsync({ ...h, address: d.ProjectTokenHooks, functionName: "withdraw" })}
                />
              </div>
            </div>
          )}
        </div>
      </Card>
    </div>
  );
}

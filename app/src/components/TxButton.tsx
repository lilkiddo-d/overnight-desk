"use client";

import { useState } from "react";
import type { ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { useAccount, usePublicClient, useReadContract, useSwitchChain, useWriteContract } from "wagmi";
import { maxUint256 } from "viem";
import type { Address, Hash, TransactionReceipt } from "viem";
import { ERC20Abi } from "@/abi";
import { explorerTxUrl } from "@/config/chains";
import { SUPPORTED_CHAIN_IDS } from "@/config/wagmi";
import { errMsg, fmtAmount } from "@/lib/format";
import { useAppChainId } from "@/providers/DeploymentProvider";
import { useRisk } from "@/providers/RiskProvider";

export type Approval = {
  token: Address;
  spender: Address;
  amount: bigint;
  symbol?: string;
  decimals?: number;
};

export type PreStep = {
  needed: boolean;
  label: string;
  run: () => Promise<Hash>;
};

type Status = "idle" | "approving" | "prestep" | "signing" | "pending" | "confirmed" | "error";

export type TxButtonProps = {
  label: string;
  action: () => Promise<Hash>;
  approval?: Approval;
  preStep?: PreStep;
  onConfirmed?: (receipt: TransactionReceipt) => void;
  /** Called right before the action transaction is requested (e.g. persist secrets). Throw to abort. */
  beforeAction?: () => void | Promise<void>;
  disabled?: boolean;
  disabledReason?: string;
  /** Trading actions require the risk acknowledgment; unwinding actions (repay, claim, settle...) do not. */
  requireRiskAck?: boolean;
  variant?: "primary" | "secondary" | "danger";
  className?: string;
  small?: boolean;
};

/**
 * Wallet-aware transaction button: connect -> switch network -> risk acknowledgment -> (approve) -> action,
 * with pending / confirmed / error states and an explorer link.
 */
export function TxButton(p: TxButtonProps) {
  const chainId = useAppChainId();
  const { address, isConnected, chainId: walletChainId } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { switchChain, isPending: switching } = useSwitchChain();
  const risk = useRisk();
  const publicClient = usePublicClient({ chainId });
  const queryClient = useQueryClient();
  const { writeContractAsync } = useWriteContract();
  const [status, setStatus] = useState<Status>("idle");
  const [hash, setHash] = useState<Hash | undefined>();
  const [error, setError] = useState<string | undefined>();

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: p.approval?.token,
    abi: ERC20Abi,
    functionName: "allowance",
    args: [address as Address, p.approval?.spender as Address],
    chainId,
    query: { enabled: !!p.approval && !!address },
  });

  const needsApproval = !!p.approval && p.approval.amount > 0n && (allowance === undefined || allowance < p.approval.amount);
  const busy = status === "approving" || status === "prestep" || status === "signing" || status === "pending";
  const size = p.small ? "px-3 py-1.5 text-xs" : "";
  const variantCls =
    p.variant === "secondary" ? "btn-secondary" : p.variant === "danger" ? "btn-danger" : "btn-primary";
  const cls = `${variantCls} ${size} ${p.className ?? ""}`;

  async function wait(h: Hash): Promise<TransactionReceipt> {
    if (!publicClient) throw new Error("No RPC client for this network");
    const r = await publicClient.waitForTransactionReceipt({ hash: h });
    if (r.status !== "success") throw new Error("Transaction reverted");
    return r;
  }

  async function run() {
    setError(undefined);
    setHash(undefined);
    try {
      if (p.approval && needsApproval) {
        setStatus("approving");
        const h = await writeContractAsync({
          address: p.approval.token,
          abi: ERC20Abi,
          functionName: "approve",
          // exact-amount approvals: no standing unlimited allowance to protocol contracts
          args: [p.approval.spender, p.approval.amount > maxUint256 ? maxUint256 : p.approval.amount],
          chainId,
        });
        setHash(h);
        await wait(h);
        await refetchAllowance();
      }
      if (p.preStep?.needed) {
        setStatus("prestep");
        const h = await p.preStep.run();
        setHash(h);
        await wait(h);
      }
      if (p.beforeAction) await p.beforeAction();
      setStatus("signing");
      const h = await p.action();
      setHash(h);
      setStatus("pending");
      const receipt = await wait(h);
      setStatus("confirmed");
      p.onConfirmed?.(receipt);
      await queryClient.invalidateQueries();
    } catch (e) {
      setStatus("error");
      setError(errMsg(e));
    }
  }

  let button: ReactNode;
  if (!isConnected) {
    button = (
      <button type="button" className={cls} onClick={() => openConnectModal?.()}>
        Connect wallet
      </button>
    );
  } else if (walletChainId === undefined || !SUPPORTED_CHAIN_IDS.includes(walletChainId) || walletChainId !== chainId) {
    button = (
      <button type="button" className={cls} disabled={switching} onClick={() => switchChain({ chainId })}>
        {switching ? "Switching…" : "Switch network"}
      </button>
    );
  } else if ((p.requireRiskAck ?? true) && !risk.accepted) {
    button = (
      <button type="button" className={cls} onClick={risk.open}>
        Accept risk disclosure to continue
      </button>
    );
  } else {
    const label =
      status === "approving"
        ? "Approving…"
        : status === "prestep"
          ? `${p.preStep?.label ?? "Preparing"}…`
          : status === "signing"
            ? "Confirm in wallet…"
            : status === "pending"
              ? "Pending…"
              : needsApproval && p.approval
                ? `Approve ${p.approval.decimals !== undefined ? fmtAmount(p.approval.amount, p.approval.decimals) + " " : ""}${p.approval.symbol ?? "token"} & ${p.label}`
                : p.preStep?.needed
                  ? `${p.preStep.label} & ${p.label}`
                  : p.label;
    button = (
      <button type="button" className={cls} disabled={p.disabled || busy} onClick={run} title={p.disabledReason}>
        {label}
      </button>
    );
  }

  const link = hash ? explorerTxUrl(chainId, hash) : null;
  return (
    <div className="flex min-w-0 flex-col gap-1">
      {button}
      {p.disabled && p.disabledReason && isConnected && !busy && (
        <p className="text-xs text-muted">{p.disabledReason}</p>
      )}
      {status === "confirmed" && (
        <p className="text-xs text-good">
          Confirmed{" "}
          {link && (
            <a className="underline" href={link} target="_blank" rel="noreferrer">
              view on explorer
            </a>
          )}
        </p>
      )}
      {status === "pending" && hash && (
        <p className="text-xs text-muted">
          Submitted{" "}
          {link ? (
            <a className="underline" href={link} target="_blank" rel="noreferrer">
              {hash.slice(0, 10)}…
            </a>
          ) : (
            <span className="font-mono">{hash.slice(0, 10)}…</span>
          )}
        </p>
      )}
      {status === "error" && error && <p className="break-words text-xs text-bad">{error}</p>}
    </div>
  );
}

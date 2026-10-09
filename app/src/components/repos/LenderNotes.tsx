"use client";

import Link from "next/link";
import { useMemo } from "react";
import { useAccount, useReadContracts, useWriteContract } from "wagmi";
import type { Address } from "viem";
import { RepoLockerAbi } from "@/abi";
import { TxButton } from "@/components/TxButton";
import { Badge, Card, Countdown, Empty } from "@/components/ui";
import { useMyNotes, useSeries } from "@/hooks/useNotes";
import { bookName, useBooks, useClock, useStable } from "@/hooks/useProtocol";
import { fmtAmount, fmtBps, fmtTime } from "@/lib/format";
import { useAppChainId, useDeployment } from "@/providers/DeploymentProvider";

export function LenderNotes() {
  const chainId = useAppChainId();
  const d = useDeployment();
  const { address } = useAccount();
  const clock = useClock();
  const stable = useStable();
  const { books } = useBooks();
  const notes = useMyNotes();
  const ids = useMemo(() => notes.map((n) => n.id), [notes]);
  const series = useSeries(ids);
  const { writeContractAsync } = useWriteContract();
  const bookById = useMemo(() => new Map(books.map((b) => [b.id, b])), [books]);

  const { data: previews } = useReadContracts({
    contracts: notes.map(
      (n) => ({ address: d?.RepoLocker as Address, abi: RepoLockerAbi, functionName: "previewRedeem", args: [n.id, n.balance], chainId }) as const,
    ),
    query: { enabled: !!d && notes.length > 0, refetchInterval: 30_000 },
  });

  return (
    <Card
      title="My repo notes (lender)"
      actions={
        <Link href="/notes" className="text-xs text-accent underline">
          Sell on the note market
        </Link>
      }
    >
      {!address ? (
        <Empty>Connect a wallet to see your notes.</Empty>
      ) : notes.length === 0 ? (
        <Empty>No repo notes. Notes are minted when you settle a filled lend order.</Empty>
      ) : (
        <div className="-mx-2 overflow-x-auto">
          <table className="table">
            <thead>
              <tr>
                <th>Series</th>
                <th>Book</th>
                <th>Rate</th>
                <th>Units</th>
                <th>Maturity</th>
                <th>Open repos</th>
                <th>Redeem value now</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {notes.map((n, i) => {
                const s = series.get(n.id.toString());
                const preview = previews?.[i]?.status === "success" ? (previews[i].result as bigint) : undefined;
                const settled = s && s.openRepos === 0;
                return (
                  <tr key={n.id.toString()}>
                    <td className="font-mono">#{n.id.toString()}</td>
                    <td>{s ? bookName(bookById.get(s.bookId)) : "-"}</td>
                    <td>{s ? fmtBps(s.rateBps) : "-"}</td>
                    <td>{fmtAmount(n.balance, stable?.decimals, 2)}</td>
                    <td>
                      {s ? (
                        clock.now < s.maturity ? (
                          <Countdown to={s.maturity} now={clock.now} />
                        ) : (
                          fmtTime(s.maturity)
                        )
                      ) : (
                        "-"
                      )}
                    </td>
                    <td>
                      {s ? settled ? <Badge tone="good">settled</Badge> : s.openRepos : "-"}
                      {s && s.badDebt > 0n && (
                        <span className="ml-2">
                          <Badge tone="bad">bad debt {fmtAmount(s.badDebt, stable?.decimals, 2)}</Badge>
                        </span>
                      )}
                    </td>
                    <td>{settled ? `${fmtAmount(preview, stable?.decimals, 2)} ${stable?.symbol ?? ""}` : <span className="text-muted">after all repos close</span>}</td>
                    <td>
                      {settled && (
                        <TxButton
                          small
                          label="Redeem"
                          requireRiskAck={false}
                          action={() =>
                            writeContractAsync({ address: d!.RepoLocker, abi: RepoLockerAbi, functionName: "redeem", args: [n.id, n.balance], chainId })
                          }
                        />
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}

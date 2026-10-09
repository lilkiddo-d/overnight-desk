"use client";

import Link from "next/link";
import { useState } from "react";

const ITEMS = [
  "I am not a US person and I am not located in, or a resident of, a restricted or sanctioned jurisdiction.",
  "I understand loans can be liquidated by Dutch auction, including after overnight or weekend price gaps.",
  "I understand smart-contract, oracle, stablecoin (USDG) and token-issuer risks (pauses, blocklists), and that I can lose all funds I deposit.",
  "I understand sealed orders must be revealed in the reveal window, or 1% of the escrow is forfeited, and that I must keep my order backup safe.",
  "Nothing here is investment advice. I act on my own judgment.",
];

export function RiskModal({ onAccept, onClose }: { onAccept: () => void; onClose: () => void }) {
  const [checked, setChecked] = useState<boolean[]>(ITEMS.map(() => false));
  const all = checked.every(Boolean);
  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 p-0 sm:items-center sm:p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="risk-title"
    >
      <div className="max-h-[92vh] w-full max-w-lg overflow-y-auto rounded-t-2xl border border-line bg-panel p-5 shadow-2xl sm:rounded-2xl">
        <h2 id="risk-title" className="text-lg font-semibold">
          Before you use Overnight Desk
        </h2>
        <p className="mt-2 text-sm text-muted">
          Overnight Desk is non-custodial software for fixed-term, fixed-rate loans backed by tokenized stocks. Please
          read the{" "}
          <Link href="/risk" className="text-accent underline" onClick={onClose}>
            full risk disclosure
          </Link>{" "}
          and confirm each statement.
        </p>
        <ul className="mt-4 space-y-3">
          {ITEMS.map((text, i) => (
            <li key={i}>
              <label className="flex cursor-pointer gap-3 text-sm">
                <input
                  type="checkbox"
                  className="mt-0.5 h-4 w-4 shrink-0 accent-[var(--color-accent)]"
                  checked={checked[i]}
                  onChange={(e) => setChecked((c) => c.map((v, j) => (j === i ? e.target.checked : v)))}
                />
                <span>{text}</span>
              </label>
            </li>
          ))}
        </ul>
        <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <button type="button" className="btn-secondary" onClick={onClose}>
            Not now (view only)
          </button>
          <button type="button" className="btn-primary" disabled={!all} onClick={onAccept}>
            I understand and accept
          </button>
        </div>
      </div>
    </div>
  );
}

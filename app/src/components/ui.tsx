"use client";

import type { ReactNode } from "react";
import { fmtCountdown } from "@/lib/format";
import { PHASE_NAMES } from "@/lib/math";
import type { PhaseId } from "@/lib/math";

export function Card({ title, actions, children, className }: { title?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`card ${className ?? ""}`}>
      {(title || actions) && (
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          {title && <h2 className="text-sm font-semibold uppercase tracking-wide text-muted">{title}</h2>}
          {actions}
        </div>
      )}
      {children}
    </section>
  );
}

export function Stat({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return (
    <div className="min-w-0">
      <div className="text-xs text-muted">{label}</div>
      <div className="truncate text-lg font-semibold tabular-nums">{value}</div>
      {sub && <div className="text-xs text-muted">{sub}</div>}
    </div>
  );
}

export function Field({ label, hint, children }: { label: string; hint?: ReactNode; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      <span className="text-muted">{label}</span>
      {children}
      {hint && <span className="text-xs text-muted">{hint}</span>}
    </label>
  );
}

const PHASE_CLS: Record<PhaseId, string> = {
  0: "bg-zinc-700/40 text-zinc-300",
  1: "bg-sky-500/15 text-sky-300",
  2: "bg-amber-500/15 text-amber-300",
  3: "bg-violet-500/15 text-violet-300",
  4: "bg-zinc-700/40 text-zinc-400",
};

export function PhaseBadge({ phase }: { phase: PhaseId | undefined }) {
  if (phase === undefined) return <span className="badge bg-zinc-800 text-zinc-400">…</span>;
  return <span className={`badge ${PHASE_CLS[phase]}`}>{PHASE_NAMES[phase]}</span>;
}

export function Badge({ tone, children }: { tone: "good" | "warn" | "bad" | "info" | "muted"; children: ReactNode }) {
  const cls = {
    good: "bg-emerald-500/15 text-emerald-300",
    warn: "bg-amber-500/15 text-amber-300",
    bad: "bg-red-500/15 text-red-300",
    info: "bg-sky-500/15 text-sky-300",
    muted: "bg-zinc-700/40 text-zinc-300",
  }[tone];
  return <span className={`badge ${cls}`}>{children}</span>;
}

/** Countdown to a chain timestamp, given the current chain time. */
export function Countdown({ to, now, label }: { to: bigint | undefined; now: bigint; label?: string }) {
  if (to === undefined) return <span className="text-muted">-</span>;
  const left = to - now;
  return (
    <span className="tabular-nums" title={new Date(Number(to) * 1000).toLocaleString()}>
      {label && <span className="text-muted">{label} </span>}
      {left > 0n ? fmtCountdown(left) : "now"}
    </span>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="rounded-lg border border-dashed border-line p-6 text-center text-sm text-muted">{children}</div>;
}

export function Notice({ tone = "info", children }: { tone?: "info" | "warn" | "bad"; children: ReactNode }) {
  const cls = {
    info: "border-sky-500/30 bg-sky-500/10 text-sky-200",
    warn: "border-amber-500/30 bg-amber-500/10 text-amber-200",
    bad: "border-red-500/40 bg-red-500/10 text-red-200",
  }[tone];
  return <div className={`rounded-lg border px-3 py-2 text-sm ${cls}`}>{children}</div>;
}

export function Spinner() {
  return <span className="inline-block h-3 w-3 animate-spin rounded-full border-2 border-muted border-t-transparent" />;
}

"use client";

import { fmtDuration } from "@/lib/format";

export type CurvePoint = { label: string; duration: number; rateBps: number | null; epoch?: bigint };

/** Minimal dependency-free SVG line chart of clearing rate vs. term. */
export function RateChart({ points }: { points: CurvePoint[] }) {
  const W = 640;
  const H = 260;
  const pad = { l: 48, r: 16, t: 16, b: 40 };
  const valid = points.filter((p) => p.rateBps !== null) as (CurvePoint & { rateBps: number })[];
  const maxRate = Math.max(100, ...valid.map((p) => p.rateBps));
  const yMax = Math.ceil((maxRate * 1.2) / 100) * 100; // round up to a whole percent
  const n = points.length;
  const x = (i: number) => pad.l + (n <= 1 ? (W - pad.l - pad.r) / 2 : (i * (W - pad.l - pad.r)) / (n - 1));
  const y = (bps: number) => pad.t + (1 - bps / yMax) * (H - pad.t - pad.b);
  const ticks = Array.from({ length: 5 }, (_, i) => (yMax * i) / 4);
  const path = points
    .map((p, i) => (p.rateBps === null ? null : `${x(i)},${y(p.rateBps)}`))
    .filter(Boolean)
    .join(" L ");

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="h-auto w-full" role="img" aria-label="Clearing rate by term">
      {ticks.map((t) => (
        <g key={t}>
          <line x1={pad.l} x2={W - pad.r} y1={y(t)} y2={y(t)} stroke="var(--color-line)" strokeDasharray="3 4" />
          <text x={pad.l - 8} y={y(t) + 4} textAnchor="end" fontSize="11" fill="var(--color-muted)">
            {(t / 100).toFixed(1)}%
          </text>
        </g>
      ))}
      {points.map((p, i) => (
        <text key={p.label + i} x={x(i)} y={H - pad.b + 20} textAnchor="middle" fontSize="12" fill="var(--color-muted)">
          {p.label || fmtDuration(p.duration)}
        </text>
      ))}
      {valid.length > 1 && <path d={`M ${path}`} fill="none" stroke="var(--color-accent)" strokeWidth="2.5" />}
      {points.map((p, i) =>
        p.rateBps === null ? (
          <g key={"n" + i}>
            <circle cx={x(i)} cy={y(0)} r="4" fill="none" stroke="var(--color-muted)" strokeDasharray="2 2" />
            <text x={x(i)} y={y(0) - 10} textAnchor="middle" fontSize="11" fill="var(--color-muted)">
              no fill
            </text>
          </g>
        ) : (
          <g key={"p" + i}>
            <circle cx={x(i)} cy={y(p.rateBps)} r="5" fill="var(--color-bg)" stroke="var(--color-accent)" strokeWidth="2.5" />
            <text x={x(i)} y={y(p.rateBps) - 12} textAnchor="middle" fontSize="12" fontWeight="600" fill="var(--color-fg)">
              {(p.rateBps / 100).toFixed(2)}%
            </text>
          </g>
        ),
      )}
    </svg>
  );
}

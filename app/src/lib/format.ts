import { formatUnits, parseUnits } from "viem";

/** Format a token amount with thousands separators and at most `maxFrac` fraction digits (truncating). */
export function fmtAmount(value: bigint | undefined | null, decimals: number | undefined, maxFrac = 4): string {
  if (value === undefined || value === null || decimals === undefined) return "-";
  const neg = value < 0n;
  const s = formatUnits(neg ? -value : value, decimals);
  const [whole, frac = ""] = s.split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const f = frac.slice(0, maxFrac).replace(/0+$/, "");
  return `${neg ? "-" : ""}${grouped}${f ? "." + f : ""}`;
}

/** Parse a user-entered decimal string into token units. Returns null when invalid or too precise. */
export function parseAmount(input: string, decimals: number | undefined): bigint | null {
  if (decimals === undefined) return null;
  const s = input.trim().replace(/,/g, "");
  if (!/^\d*(\.\d*)?$/.test(s) || s === "" || s === ".") return null;
  const frac = s.split(".")[1] ?? "";
  if (frac.length > decimals) return null;
  try {
    return parseUnits(s, decimals);
  } catch {
    return null;
  }
}

export function fmtBps(bps: number | bigint | undefined, digits = 2): string {
  if (bps === undefined) return "-";
  return `${(Number(bps) / 100).toFixed(digits)}%`;
}

export function fmtPct(fraction: number | null | undefined, digits = 2): string {
  if (fraction === null || fraction === undefined || !Number.isFinite(fraction)) return "-";
  return `${(fraction * 100).toFixed(digits)}%`;
}

export function fmtUsdE18(priceE18: bigint | undefined, digits = 2): string {
  if (priceE18 === undefined) return "-";
  return "$" + fmtAmount(priceE18, 18, digits);
}

/** Countdown text: "2d 03:04:05" / "03:04:05" / "04:05". */
export function fmtCountdown(seconds: bigint | number): string {
  let s = Math.max(0, Math.floor(Number(seconds)));
  const d = Math.floor(s / 86_400);
  s -= d * 86_400;
  const h = Math.floor(s / 3_600);
  s -= h * 3_600;
  const m = Math.floor(s / 60);
  s -= m * 60;
  const pad = (n: number) => n.toString().padStart(2, "0");
  if (d > 0) return `${d}d ${pad(h)}:${pad(m)}:${pad(s)}`;
  if (h > 0) return `${pad(h)}:${pad(m)}:${pad(s)}`;
  return `${pad(m)}:${pad(s)}`;
}

/** Human duration for term lengths: 86400 -> "1d", 3600 -> "1h". */
export function fmtDuration(seconds: number | bigint): string {
  const s = Number(seconds);
  if (s >= 86_400 && s % 86_400 === 0) return `${s / 86_400}d`;
  if (s >= 86_400) return `${(s / 86_400).toFixed(1)}d`;
  if (s >= 3_600) return `${(s / 3_600).toFixed(s % 3_600 === 0 ? 0 : 1)}h`;
  return `${Math.round(s / 60)}m`;
}

export function fmtTime(ts: bigint | number | undefined): string {
  if (ts === undefined) return "-";
  const n = Number(ts);
  if (!n) return "-";
  return new Date(n * 1000).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function shortAddr(a: string | undefined): string {
  if (!a) return "-";
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

/** Best-effort human message from a viem / wallet error. */
export function errMsg(e: unknown): string {
  if (!e) return "Unknown error";
  const anyE = e as { shortMessage?: string; message?: string; cause?: unknown; details?: string };
  const msg = anyE.shortMessage || anyE.message || String(e);
  if (/user rejected|denied transaction|rejected the request/i.test(msg)) return "Rejected in wallet";
  return msg.split("\n")[0].slice(0, 240);
}

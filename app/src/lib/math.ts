// Pure fixed-point helpers mirroring contracts/src/libraries/RepoMath.sol (ACT/365 simple interest, BPS).
// Self-contained (no local imports) so `node --test` can run it with type stripping.

export const BPS = 10_000n;
export const YEAR = 365n * 24n * 60n * 60n;
export const E18 = 10n ** 18n;

export function mulDiv(a: bigint, b: bigint, c: bigint, roundUp = false): bigint {
  if (c === 0n) throw new Error("division by zero");
  const p = a * b;
  const q = p / c;
  return roundUp && q * c !== p ? q + 1n : q;
}

/** RepoMath.interest: simple interest, rounded up. */
export function interest(principal: bigint, rateBps: bigint | number, elapsed: bigint | number): bigint {
  return mulDiv(principal, BigInt(rateBps) * BigInt(elapsed), BPS * YEAR, true);
}

/** RepoMath.fee: annualised auction fee for a term, after a discount, rounded down. */
export function auctionFee(
  principal: bigint,
  feeBpsPerYear: bigint | number,
  duration: bigint | number,
  discountBps: bigint | number = 0n,
): bigint {
  const d = BigInt(discountBps);
  if (d >= BPS) return 0n;
  const gross = mulDiv(principal, BigInt(feeBpsPerYear) * BigInt(duration), BPS * YEAR);
  return mulDiv(gross, BPS - d, BPS);
}

/** RepoMath.value: collateral `amount` at `priceE18` (USD per whole token) in stablecoin units. */
export function collateralValue(
  amount: bigint,
  collDecimals: number,
  priceE18: bigint,
  stableDecimals: number,
  roundUp = false,
): bigint {
  return mulDiv(amount * priceE18, 10n ** BigInt(stableDecimals), 10n ** BigInt(collDecimals) * E18, roundUp);
}

/** RepoMath.collateralFor: collateral worth `stableAmount`, rounded up. */
export function collateralFor(stableAmount: bigint, collDecimals: number, priceE18: bigint, stableDecimals: number): bigint {
  if (priceE18 === 0n) throw new Error("zero price");
  return mulDiv(stableAmount, 10n ** BigInt(collDecimals) * E18, priceE18 * 10n ** BigInt(stableDecimals), true);
}

export function applyHaircut(amount: bigint, haircutBps: bigint | number): bigint {
  return mulDiv(amount, BPS - BigInt(haircutBps), BPS);
}

/** Max stablecoin principal that `collateral` supports at the initial haircut (MarginEngine.meetsInitialMargin). */
export function maxBorrowable(
  collateral: bigint,
  collDecimals: number,
  priceE18: bigint,
  stableDecimals: number,
  initialHaircutBps: number,
): bigint {
  return applyHaircut(collateralValue(collateral, collDecimals, priceE18, stableDecimals), initialHaircutBps);
}

/** Smallest collateral amount for which `borrow <= value * (1 - initialHaircut)` holds (exact, with rounding). */
export function requiredCollateral(
  borrow: bigint,
  collDecimals: number,
  priceE18: bigint,
  stableDecimals: number,
  initialHaircutBps: number,
): bigint {
  if (borrow === 0n) return 0n;
  const h = BigInt(initialHaircutBps);
  if (h >= BPS) throw new Error("bad haircut");
  const grossValue = mulDiv(borrow, BPS, BPS - h, true);
  let c = collateralFor(grossValue, collDecimals, priceE18, stableDecimals);
  // flooring inside value() / applyHaircut() can leave us a few units short; step up until the check passes
  const step = c / 1_000_000n > 0n ? c / 1_000_000n : 1n;
  for (let i = 0; i < 10_000 && maxBorrowable(c, collDecimals, priceE18, stableDecimals, initialHaircutBps) < borrow; i++) {
    c += step;
  }
  return c;
}

/** Repo debt at `timestamp` (RepoLocker.debtAt), capped at maturity. */
export function debtAt(principal: bigint, rateBps: number, start: bigint, maturity: bigint, timestamp: bigint): bigint {
  if (principal === 0n) return 0n;
  const end = timestamp < maturity ? timestamp : maturity;
  const elapsed = end > start ? end - start : 0n;
  return principal + interest(principal, rateBps, elapsed);
}

/**
 * Amount to approve/send for a full repayment: current debt plus the interest that can accrue over `bufferSeconds`
 * (the contract caps the payment at the actual debt, so the buffer is never spent).
 */
export function repayWithBuffer(debt: bigint, principal: bigint, rateBps: number, bufferSeconds = 900): bigint {
  return debt + interest(principal, rateBps, bufferSeconds) + 1n;
}

/** "5.25" (% p.a.) -> 525 bps. Returns null for invalid input. Up to 2 decimals. */
export function percentToBps(input: string): number | null {
  const s = input.trim();
  if (!/^\d+(\.\d{0,2})?$/.test(s)) return null;
  const [whole, frac = ""] = s.split(".");
  const bps = Number(whole) * 100 + Number((frac + "00").slice(0, 2));
  return Number.isSafeInteger(bps) ? bps : null;
}

export function bpsToPercentString(bps: number | bigint, digits = 2): string {
  return (Number(bps) / 100).toFixed(digits);
}

export type NoteYield = {
  /** expected stablecoin per note unit at maturity, as a float (1 + rate * term / 365) */
  valueAtMaturity: number;
  /** listing price per unit as a float */
  price: number;
  /** remaining time in days (0 if matured) */
  daysToMaturity: number;
  /** simple annualised yield to maturity (fraction, e.g. 0.05 = 5%); null if matured */
  annualizedYield: number | null;
};

/**
 * Implied yield of buying a note at `priceE18` (stablecoin units per note unit, E18). One unit is one unit of lent
 * principal, so a unit is expected to pay 1 + rate * term / 365 at maturity (before any bad debt or early repayment).
 */
export function noteYield(priceE18: bigint, rateBps: number, start: bigint, maturity: bigint, now: bigint): NoteYield {
  const termDays = Number(maturity - start) / 86_400;
  const valueAtMaturity = 1 + (rateBps / 10_000) * (termDays / 365);
  const price = Number(priceE18) / 1e18;
  const daysToMaturity = maturity > now ? Number(maturity - now) / 86_400 : 0;
  const annualizedYield =
    daysToMaturity > 0 && price > 0 ? (valueAtMaturity / price - 1) * (365 / daysToMaturity) : null;
  return { valueAtMaturity, price, daysToMaturity, annualizedYield };
}

/** priceE18 that gives a target simple annualised yield (inverse of noteYield). */
export function priceForYield(yieldBps: number, rateBps: number, start: bigint, maturity: bigint, now: bigint): bigint {
  const termDays = Number(maturity - start) / 86_400;
  const daysLeft = maturity > now ? Number(maturity - now) / 86_400 : 0;
  const v = 1 + (rateBps / 10_000) * (termDays / 365);
  const p = v / (1 + (yieldBps / 10_000) * (daysLeft / 365));
  return BigInt(Math.round(p * 1e12)) * 10n ** 6n;
}

// ------------------------------------------------------------------ auction calendar (MarketClock mirror)

export const PHASE = { Pending: 0, Commit: 1, Reveal: 2, Clearing: 3, Expired: 4 } as const;
export type PhaseId = 0 | 1 | 2 | 3 | 4;
export const PHASE_NAMES = ["Pending", "Commit", "Reveal", "Clearing", "Expired"] as const;

export type ClockParams = {
  genesis: bigint;
  interval: bigint;
  commitWindow: bigint;
  revealWindow: bigint;
  clearWindow: bigint;
};

export type EpochTimes = { start: bigint; commitEnd: bigint; revealEnd: bigint; expiry: bigint };

export function epochAt(c: ClockParams, t: bigint): bigint | null {
  if (t < c.genesis) return null;
  return (t - c.genesis) / c.interval;
}

export function epochTimes(c: ClockParams, epoch: bigint): EpochTimes {
  const start = c.genesis + epoch * c.interval;
  const commitEnd = start + c.commitWindow;
  const revealEnd = commitEnd + c.revealWindow;
  return { start, commitEnd, revealEnd, expiry: revealEnd + c.clearWindow };
}

export function phaseAt(c: ClockParams, epoch: bigint, t: bigint): PhaseId {
  const e = epochTimes(c, epoch);
  if (t < e.start) return 0;
  if (t < e.commitEnd) return 1;
  if (t < e.revealEnd) return 2;
  if (t < e.expiry) return 3;
  return 4;
}

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  auctionFee,
  collateralValue,
  debtAt,
  epochAt,
  epochTimes,
  interest,
  maxBorrowable,
  noteYield,
  percentToBps,
  phaseAt,
  requiredCollateral,
  YEAR,
} from "./math.ts";

test("interest rounds up like RepoMath.interest", () => {
  // 1,000 USDG (6 dp) at 5% for a full year = 50 USDG
  assert.equal(interest(1_000_000_000n, 500, YEAR), 50_000_000n);
  // tiny elapsed rounds up to 1 unit
  assert.equal(interest(1_000_000n, 1, 1), 1n);
});

test("auction fee with discount", () => {
  // 1,000,000 USDG at 50 bps/yr for 30 days
  const f = auctionFee(1_000_000_000_000n, 50, 30 * 86_400);
  assert.equal(f, 410_958_904n);
  assert.equal(auctionFee(1_000_000_000_000n, 50, 30 * 86_400, 10_000), 0n);
});

test("collateral valuation and initial margin", () => {
  // 2 AAPL (18 dp) at $200 = 400 USDG
  const value = collateralValue(2n * 10n ** 18n, 18, 200n * 10n ** 18n, 6);
  assert.equal(value, 400_000_000n);
  // 30% initial haircut => 280 USDG borrowable
  assert.equal(maxBorrowable(2n * 10n ** 18n, 18, 200n * 10n ** 18n, 6, 3_000), 280_000_000n);
  const req = requiredCollateral(280_000_000n, 18, 200n * 10n ** 18n, 6, 3_000);
  assert.ok(maxBorrowable(req, 18, 200n * 10n ** 18n, 6, 3_000) >= 280_000_000n);
  assert.ok(req <= 2n * 10n ** 18n + 10n);
});

test("debt is capped at maturity", () => {
  const d1 = debtAt(1_000_000n, 1_000, 0n, YEAR, YEAR * 2n);
  assert.equal(d1, 1_100_000n);
});

test("percentToBps parses strictly", () => {
  assert.equal(percentToBps("5.25"), 525);
  assert.equal(percentToBps("5"), 500);
  assert.equal(percentToBps("0.1"), 10);
  assert.equal(percentToBps("1.234"), null);
  assert.equal(percentToBps("-1"), null);
  assert.equal(percentToBps("abc"), null);
});

test("note yield at par equals the series rate for a fresh note", () => {
  const start = 0n;
  const maturity = 365n * 86_400n;
  const y = noteYield(10n ** 18n, 500, start, maturity, start);
  assert.ok(Math.abs((y.annualizedYield ?? 0) - 0.05) < 1e-9);
  const matured = noteYield(10n ** 18n, 500, start, maturity, maturity + 1n);
  assert.equal(matured.annualizedYield, null);
});

test("market clock mirror", () => {
  const c = { genesis: 1_000n, interval: 3_600n, commitWindow: 1_200n, revealWindow: 600n, clearWindow: 900n };
  assert.equal(epochAt(c, 999n), null);
  assert.equal(epochAt(c, 1_000n + 3_600n * 5n + 10n), 5n);
  const t = epochTimes(c, 5n);
  assert.deepEqual(t, { start: 19_000n, commitEnd: 20_200n, revealEnd: 20_800n, expiry: 21_700n });
  assert.equal(phaseAt(c, 5n, 18_999n), 0);
  assert.equal(phaseAt(c, 5n, 19_000n), 1);
  assert.equal(phaseAt(c, 5n, 20_200n), 2);
  assert.equal(phaseAt(c, 5n, 20_800n), 3);
  assert.equal(phaseAt(c, 5n, 21_700n), 4);
});

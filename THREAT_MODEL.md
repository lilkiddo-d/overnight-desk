# Threat model: Overnight Desk

Scope: `contracts/src/**` as deployed by `contracts/script/Deploy.s.sol` on Robinhood Chain (chain 4663), plus the keeper (`scripts/`) and frontend (`app/`) as they affect on-chain safety.

## 1. Assets at risk

| Asset | Held by | Notes |
|---|---|---|
| Lender stablecoin (USDG) in open orders | AuctionHouse | Escrowed at commit; refunded or matched |
| Borrower collateral in open orders | AuctionHouse | Escrowed at commit |
| Collateral of open repos | RepoLocker | Accounted per repo (`lockedCollateral` mirror) |
| Series cash owed to noteholders, claimable surpluses | RepoLocker | `totalStableLiabilities` mirror |
| Collateral under liquidation | Liquidator | Per-auction accounting |
| Protocol fees | FeeCollector, then treasury / stakers | |
| $OVND stake and staking rewards | ProjectTokenHooks | Dormant until the token is set |

## 2. Actors and trust

| Actor | Powers | Trust |
|---|---|---|
| Timelock (48h, floor enforced in code) | `DEFAULT_ADMIN_ROLE` everywhere: parameters, oracle swaps, roles, `setProjectToken` | Trusted, but delayed; users can exit within 48h |
| Timelock proposer / executor (multisig) | Schedules and executes Timelock operations | Should be a multisig (see DEPLOY.md) |
| Guardian | Pause / unpause only; maintains the compliance allowlist | Semi-trusted; cannot move funds or change parameters |
| Keeper(s) | Nothing privileged; every keeper action is permissionless | Untrusted; liveness only |
| Chainlink feeds | Price input | Trusted with staleness bounds |
| Stock-token issuer | Can pause tokens, blocklist addresses, force-burn | External trust assumption |
| Users | Orders, repay, liquidate, trade notes | Untrusted |

## 3. Top risks (as requested)

### 3.1 Bid shading and reveal griefing

**Threat:** bidders shade bids strategically, or commit and then selectively withhold reveals to manipulate the clearing rate (a free option), or spam commitments to fill the per-book order cap.

**Mitigations:**
- **Uniform-price clearing.** Every matched order gets the same rate, so the dominant strategy is to bid your true limit; shading only risks not being filled.
- **Escrow at commit.** Amounts are public and fully escrowed, so a revealed bid is always fully funded. A non-revealed bid can only remove itself, never inject unbacked size.
- **No-reveal penalty.** 1% of escrow (configurable, max 10%) goes to the FeeCollector, which makes the "option" of withholding a reveal costly.
- **Commitments bind owner, book, epoch, side, amount, collateral and salt.** They cannot be copied or replayed.
- **Spam is costly.** The order cap (50 per side) plus `minOrderSize` (100 USDG) plus the 1% penalty make filling a book expensive; filling a book only delays (doesn't steal) and leftover rollover carries good orders forward.
- **Reveal is not pausable.** Anyone holding the preimage can reveal, so users can delegate reveals and a pause can never trigger penalties.
- **Clearing-rate invariant.** Tested: the rate lies between the marginal lender and borrower limits; the volume is maximal; priority holds (`test/fuzz/Clearing.fuzz.t.sol`, `invariant_clearingRespectsLimits`).

**Residual:** amounts are public, so a large lender's presence is visible. The frontend never calls `commitmentHash` over RPC, which would leak the rate to the RPC provider.

### 3.2 Collateral gaps at market open

**Threat:** stock prices gap over weekends or overnight. The Chainlink equity feeds update 24/5, so collateral can be worth far less at the first fresh print than at the last one, and repos can become undercollateralized before any margin call cures them.

**Mitigations:**
- **Haircuts sized for gaps.** Initial 30–35% and maintenance 20–25% for single stocks; 20% / 12% for SPY.
- **Immediate liquidation when collateral net of penalty no longer covers debt.** There is no grace period once a gap has blown through the cushion.
- **Market-hours gate.** Liquidations start only inside the configured window (24/5) and on prices within the staleness limit, so a gap is liquidated at the first fresh price rather than a stale Friday close.
- **Separate staleness limits for closed vs. open market.** 3.5 days closed, 26h open, so auctions and margin checks keep working over a weekend on the last valid print.
- **Initial-margin re-check at clearing.** Borrow bids are checked against the clearing-time price, not the commit-time price.
- **Restartable Dutch auctions.** They start above oracle and restart at a fresh price if unsold at the floor.
- **Bad debt is explicit.** Shortfall is written off against the series that lent into it (no socialization across series), and noteholders redeem pro-rata. The `invariant_seriesBacking` test proves losses arise only through liquidation.

**Residual:** a gap larger than the haircut causes lender losses. This is disclosed on the risk page.

### 3.3 Keeper failure

**Threat:** nobody clears auctions, pokes margins, rolls repos or restarts liquidation auctions.

**Mitigations:**
- **Permissionless keeper functions.** `clear`, `poke`/`pokeBatch`, `submitRepoRoll`, `restart` and `distribute` can be called by any user, and the frontend exposes Clear.
- **Expiry refund.** An uncleared auction becomes fully refundable at `expiry` (24h after the reveal window), with no penalty.
- **Repayment is never gated by keepers or pause.** Borrowers can always repay and top up; overdue repos become liquidatable by anyone's poke.
- **The keeper fails safe.** It simulates every transaction before sending, isolates per-repo failures (`pokeBatch` uses try/catch), and multiple keepers can run concurrently.

**Residual:** if no one pokes during a crash, the time spent undercollateralized grows. Operators should run at least two keepers on independent infrastructure and RPC providers.

## 4. Other threats

| Threat | Mitigation |
|---|---|
| Reentrancy | `nonReentrant` on every external state-changing entry point; checks-effects-interactions (Liquidator.buy settles state before any transfer); pull payments for refunds, proceeds and notes |
| Malicious token / receiver bricking auction clearing | No user-directed transfers inside `clear()`: proceeds, notes and refunds are claimed per order via `settle`; roll-path collateral returns are credited to `claimable` |
| Stock-token issuer pause or blocklist | Blocks only the affected user's own settlement/claim; repos with blocklisted borrowers can still be liquidated (the locker sends to the Liquidator, a protocol contract). If the issuer pauses the token itself, liquidation buys revert; the guardian can pause and the Timelock can raise staleness/grace. Disclosed. |
| Oracle manipulation / outage | Chainlink only, with staleness checks, positive answer, completed round, and decimals normalization; an optional secondary-feed deviation check and sequencer-uptime check (both unset at launch because they don't exist on this chain — see DECISIONS.md). Stale oracle ⇒ margin calls and liquidations halt and clearing reverts until fresh, never mispriced. Repay and top-up stay available (`_tryCure` catches oracle reverts). |
| Unbounded loops / gas DoS | Per-book order cap (≤64, default 50); `pokeBatch` ≤100; allowlist batch ≤200; clearing is O((n+m)²) on bounded n and m (worst case well within the 32M block gas limit) |
| Rounding drift | Interest rounds up (for lenders); partial repay floors the principal reduction; pro-rata dust is assigned unit by unit; collateral locked rounds up; redemption uses the outstanding-units denominator (late note claims can't be diluted); `invariant_custody` checks every token balance against internal accounting |
| Admin key compromise | 48h Timelock (floor enforced in code) on everything; the guardian can only pause; the deployer renounces admin (asserted in `_postflight`) |
| Front-running reveals | Reveal only discloses after commits close; the clearing outcome doesn't depend on reveal order |
| Note-market slippage | `buy` takes a max price and a deadline; the seller can change the price at any time, which the max price protects against |
| Liquidation slippage | `buy` takes a max price and a deadline; the price decays monotonically within an auction |
| Flash staking for fees or discounts | 3-day minimum stake age for the discount; 7-day unstake cooldown; rewards accrue via an accumulator from the time of stake |
| Compliance misuse | Off by default; never gates exits (repay, redeem, settle, cancel, claim) |
| Sequencer downtime (Arbitrum Orbit) | Timestamp-based logic only; grace periods ≥1h; uptime-feed hook ready |

## 5. Static analysis

- Slither 0.11.6 (`cd contracts && forge build --build-info --skip "./test/**" "./script/**" && slither . --ignore-compile`): **0 High, 0 Medium.**
- Each of the following false positives is suppressed with an inline `slither-disable-start/end` block that states the reason:

| Finding | Why it's a false positive |
|---|---|
| `weak-prng` in `MarketClock` | Calendar arithmetic, not randomness |
| `uninitialized-state` on the book mappings | Written through storage pointers |
| `incorrect-equality` | Exact-zero / full-fill checks on internally tracked amounts |
| `unused-return` | Intentionally ignored oracle tuple fields |
| `reentrancy-no-eth` in `AuctionHouse.clear` | Trusted, role-gated protocol callees under `nonReentrant` |

- Remaining Low/Informational findings are reviewed and accepted:

| Finding | Why accepted |
|---|---|
| `timestamp` | The protocol is time-based by design; Arbitrum timestamps are sequencer-set within bounds |
| `calls-loop` | Bounded loops over trusted protocol contracts |
| `reentrancy-benign` / `reentrancy-events` | Event ordering after trusted calls |
| `unindexed-event-address`, `costly-loop`, `cyclomatic-complexity`, `missing-inheritance` | Style / informational |

## 6. Test evidence

- Unit tests for every contract, plus fuzz tests (clearing properties, interest/fee/valuation math).
- Stateful invariants: active repos are healthy or flagged; series backing; custody; clearing limits.
- Fork tests against Robinhood Chain mainnet with real USDG, TSLA and Chainlink feeds.
- Coverage numbers are in README.md.

## 7. Out of scope / recommended before scale

- An independent audit, and a bug bounty.
- A second oracle source and a sequencer-uptime feed once available on the chain.
- Monitoring and alerting: oracle staleness, margin calls, keeper heartbeat, Timelock queue.

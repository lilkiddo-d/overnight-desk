# Architecture

## Contracts

| Contract | Responsibility | Key roles |
|---|---|---|
| `MarketClock` | Immutable auction calendar (epoch → commit / reveal / clearing / expired); optional 24/5 market-hours window | admin: market hours |
| `TermRegistry` | Terms, collateral risk parameters (haircuts, penalty, per-auction cap), books (term × collateral), global params | admin |
| `AuctionHouse` | Commit/reveal, bounded uniform-price clearing (via the linked `ClearingLib`), pull-based settlement, leftover rollover, repo auto-roll bids | admin: wiring; guardian: pause |
| `RepoLocker` | Custody of repo collateral and series cash; repay (never paused), top-up, withdraw excess, auto-roll opt-in, note redemption, claims | `AUCTION_ROLE`, `MARGIN_ROLE`, `LIQUIDATOR_ROLE` |
| `RepoNote` | ERC-1155 notes; ID = series; 1 unit = 1 unit of lent principal | `MINTER_ROLE` (AuctionHouse), `BURNER_ROLE` (RepoLocker) |
| `MarginEngine` | Health views; permissionless `poke`/`pokeBatch` state machine (margin call → cure / liquidate; gap → immediate; overdue → liquidate) | — |
| `Liquidator` | Dutch auctions of seized collateral with max price and deadline; debt first, then penalty, then return surplus; bad-debt write-off; restart | `ENGINE_ROLE` |
| `OracleAdapter` | Per-asset primary/secondary AggregatorV3 feeds, staleness (open/closed), deviation, sequencer uptime | admin |
| `PushPriceFeed` | AggregatorV3-compatible relayed feed with a per-push jump bound (fallback / secondary) | `UPDATER_ROLE` |
| `NoteMarket` | Fixed-price note listings, partial fills, max price and deadline, fee | — |
| `FeeCollector` | Collects fees; splits stablecoin between stakers and treasury | — |
| `ProjectTokenHooks` | Dormant until `setProjectToken` (once, via the Timelock): staking, stablecoin rewards, fee-discount tier | `FEE_COLLECTOR_ROLE` |
| `ComplianceRegistry` | Off-by-default allowlist gating commits and note trades | `COMPLIANCE_ROLE` |
| `OvernightTimelock` | OZ TimelockController with a hard 48h floor; holds every `DEFAULT_ADMIN_ROLE` | proposer / executor |

## Units

- Rates: annual basis points, simple interest, ACT/365, accrued per second up to maturity.
- Prices: USD with 18 decimals per whole token (the stablecoin is treated as $1).
- Note units: stablecoin base units of lent principal. Redemption pays `units × cash / (principal − redeemed)`.

## Clearing algorithm (ClearingLib)

1. Candidate rates are every submitted rate. For each candidate `c`: supply `S(c)` is the sum of lend orders at or below `c`; demand `D(c)` is the sum of borrow orders at or above `c`. Volume is `min(S, D)`.
2. `r*` is the volume-maximising candidate; ties go to the lowest rate.
3. Matched lenders have rate ≤ `r*`; matched borrowers have rate ≥ `r*`. The clearing rate is `(max matched lend rate + min matched borrow rate) / 2`.
4. The short side fills fully. The long side fills by rate priority, and its marginal tier is rationed pro-rata, with dust handed out one unit at a time.

Complexity is O((n+m)²) with n, m ≤ 64, which takes only a few million gas.

## Lifecycle state machines

```
Order:  Committed ──reveal──► Revealed ──clear──► (filled / rolled / unfilled) ──settle──► Settled
            │                    │
            ├─cancel (commit)────┴─► Cancelled
            └─(no reveal) settle after reveal end ─► Settled (−1% penalty)
        Revealed + auction never cleared ── settle after expiry ─► Settled (full refund)

Repo:   Active ⇄ MarginCall ──grace over──► Liquidating ──auction done──► Closed
          │  └──── gap (value·(1−penalty) < debt) / overdue ───┘
          └── repay in full / roll fully ──► Closed
```

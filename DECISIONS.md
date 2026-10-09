# DECISIONS

One line per decision, with the reason. Grouped by area.

## Chain & assets
- **Target Robinhood Chain mainnet, chain ID 4663, gas token ETH.** Verified with `cast chain-id` against the official RPC ([docs](https://docs.robinhood.com/chain/connecting)).
- **USDG (Paxos Global Dollar, 6 decimals) is the loan stablecoin.** It is the only official stablecoin on the chain; there is no native Circle USDC.
- **Launch collateral: TSLA, AAPL, NVDA, SPY, AMZN, MSFT, GOOGL.** Each token and its Chainlink feed was checked with `cast` (code, symbol, decimals, live answer). META and QQQ feeds exist but did not fully verify through the flaky public RPC, so they are left for a later Timelock proposal.
- **Chainlink per-stock feeds are the primary oracle (8 decimals, 24h heartbeat, 24/5 updates, multiplier-adjusted).** They are the only oracle Robinhood's docs name.
- **No secondary oracle cross-check at launch.** Pyth, RedStone and Chronicle are not on the chain. The adapter supports a secondary feed; `PushPriceFeed` exists so an operator can relay a second source later.
- **No L2 sequencer-uptime check at launch.** No uptime feed is published for this chain. `OracleAdapter.setSequencerUptimeFeed` stays unset until one exists.
- **Staleness limits: 26h while the market is open, 3.5 days while it is closed.** That is the 24h heartbeat plus a 2h buffer, and the closed window covers a weekend plus a holiday Monday.
- **Market-hours window is 24/5 (Mon–Fri, all day UTC), not the NYSE session.** Stock tokens and their feeds trade and update 24/5; the clock gates liquidations outside that window.
- **Stock tokens are treated as standard 18-decimal ERC-20s with issuer pause/blocklist risk.** Per Robinhood docs and bytecode inspection. Every protocol-initiated transfer to a user inside auction clearing is pull-based, so one blocklisted address cannot brick an auction.
- **The local fork uses chain ID 31337 on port 8571.** That keeps wallets from confusing it with mainnet; ports 8545–8549 were already used by other projects on this machine.

## Auction design
- **Daily auctions (interval 24h): commit 18h → reveal 2h → clear window 24h, genesis at 18:00 UTC.** Clearing opens at 14:00 UTC, during US trading hours, so prices are fresh. Daily cadence matches the overnight term.
- **Amounts are public and escrowed at commit; only the rate is sealed.** Same model as Term Finance: escrow makes every revealed bid fully funded, so reveal griefing cannot create unbacked bids.
- **Commitment = keccak256(abi.encode(owner, book, epoch, side, amount, collateral, rate, salt)).** Binding the owner and epoch stops copy-paste and replay of someone else's commitment.
- **Anyone holding the preimage may reveal.** This allows delegated or automated reveal services without custody.
- **No-reveal penalty is 1% of escrow, sent to the FeeCollector.** It makes spam commits and option-like non-reveals costly; refunds are otherwise automatic.
- **Uniform price: volume-maximising rate, then the midpoint of the marginal lender and borrower rates.** Every matched order's limit is satisfied, and no order willing at the clearing rate is excluded except by rate priority. Proven by a fuzz test and an invariant.
- **Pro-rata rationing in the marginal tier, with dust assigned one unit at a time.** Both sides sum to exactly the same volume and no order is over-filled.
- **Orders are capped at 50 per side per book per auction (hard cap 64).** That bounds the O((n+m)²) clearing to well under the 32M block gas limit.
- **ClearingLib is an external (linked) library.** It keeps AuctionHouse under EIP-170 without via-IR (via-IR breaks coverage accuracy). Forge links it automatically.
- **Borrow bids failing the initial-margin check at the oracle price during clearing are excluded and refunded, not rolled.** That prevents under-collateralised matches when prices moved after commit.
- **Leftover rollover re-enters the next auction as an already-revealed order at the same limit rate.** The rate is already public after reveal; the owner can cancel during the next commit phase.
- **Repo auto-roll is a revealed, price-taking bid (borrower's max rate) sized to repay the full debt at maturity plus the fee.** It can be submitted permissionlessly by keepers; partial fills roll proportionally.
- **Lender-side rollover means leftover unmatched amounts roll; matured notes are redeemed, not auto-rolled.** That keeps notes simple ERC-1155 claims; a "redeem and recommit" flow is a frontend concern.
- **Uncleared auctions become fully refundable at expiry.** This is the keeper-failure fallback; no penalty applies when the protocol, not the user, failed.
- **Settlement is pull-based per order, never paused, and permissionless.** A malicious ERC-1155 receiver or blocklisted user only affects their own order.
- **Clearing, commits and auto-roll pause; reveal, settle, cancel, repay and top-up never pause.** A pause must never force a penalty or a liquidation on users.

## Repos, notes, margin
- **Note units = lent principal (stablecoin units); token ID = series (book × epoch).** Notes redeem pro-rata from the series cash pool once all repos in the series are closed, so losses are socialised transparently.
- **Interest is simple ACT/365, accrued per second up to maturity, rounded up.** Early repayment pays interest to date, as the spec asks; notes may therefore return less than the headline rate (disclosed).
- **Partial repayment reduces principal proportionally to debt (floor).** The borrower can never end up owing less than an exact calculation.
- **Haircuts: single stocks initial 30%, maintenance 20% (TSLA, NVDA: 35%/25%); SPY 20%/12%; liquidation penalty 5% (SPY 4%).** Higher-volatility names get wider cushions; the penalty must be less than the maintenance cushion (enforced on-chain).
- **Margin call grace is 4h; maturity grace is 4h.** Long enough for a human to cure, short enough to limit drift.
- **Immediate liquidation when collateral value (net of the penalty) no longer covers the debt.** That covers gap risk, where waiting out a grace period only increases losses.
- **Liquidations start only inside the market-hours window.** This avoids liquidating on stale Friday prices; the first fresh price after the open decides.
- **Dutch auction starts at oracle +5%, decays linearly to −15% over 2h, and is restartable at a fresh oracle price.** Buyers pass a max price and a deadline (slippage protection).
- **Liquidation proceeds go to debt first, then penalty; leftover collateral goes back to the borrower; any shortfall is recorded as series bad debt.** Accounting is transparent and the invariant-tested backing equation holds.

## Fees & token
- **Auction fee is 0.25% per year on matched principal, paid by borrowers and deducted from proceeds.** Annualised, so overnight loans are not overcharged.
- **Note-market fee is 0.10%; no-reveal penalties and liquidation penalties go to the FeeCollector.** These are simple, transparent revenue sources.
- **Before $OVND is set, 100% of fees go to the treasury.** After it is set and someone has staked, 50% of stablecoin fees go to stakers.
- **Staking discount tier is off until the Timelock sets a threshold.** It requires a minimum stake age of 3 days, and unstaking has a 7-day cooldown, so fees cannot be captured by flash-staking.
- **`setProjectToken` is one-shot and admin (Timelock) only.** As specified; no token is deployed by this repo.

## Governance & security
- **Every contract's DEFAULT_ADMIN_ROLE goes to a 48h `OvernightTimelock`; the deployer renounces.** As specified. `getMinDelay` is floored at 48h, so the delay can never be lowered.
- **Timelock proposer and executor = `TIMELOCK_PROPOSER` (default: the deployer).** For production, set a multisig before deploying (see DEPLOY.md).
- **GUARDIAN_ROLE can pause and unpause only.** Fast emergency response without parameter or fund powers.
- **ComplianceRegistry is deployed and wired but disabled.** It gates commits and note listing/buying when enabled; never exits (repay, redeem, settle, cancel).
- **No via-IR; optimizer at 200 runs, solc 0.8.28, EVM cancun.** Arbitrum Orbit supports Cancun opcodes, and the non-IR pipeline keeps coverage accurate.

## Tooling
- **Frontend reads `/deployments/<chainId>.json` at runtime.** The app builds and deploys to Vercel before mainnet contracts exist.
- **The keeper is TypeScript/viem and decrypts the Foundry keystore in memory via ethers.** viem has no keystore decryption; the key is never logged or stored.
- **The fork deploy signs with anvil's unlocked dev account (`--unlocked`); the mainnet dry run simulates with a placeholder sender.** No private key is created, requested, stored or printed anywhere.

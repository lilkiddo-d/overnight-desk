# Overnight Desk

An on-chain **repo market on Robinhood Chain**: fixed-term, fixed-rate loans in USDG, backed by tokenized stocks.

- **Terms:** overnight, 7-day, 30-day and 90-day. Every term × collateral pair is an order book of lend offers and borrow bids.
- **Matching:** daily **sealed-bid (commit/reveal) batch auctions** clear each book at a single uniform rate (Term Finance style). Unmatched remainders roll to the next auction if the user opted in.
- **On a match:** collateral locks in the `RepoLocker`, the lender receives a transferable **ERC-1155 repo note**, and the borrower receives stablecoin.
- **Risk:**
  - Per-stock initial and maintenance haircuts.
  - Margin calls with a grace period, then a **Dutch-auction liquidation**.
  - Immediate liquidation when a price gap blows through the cushion.
- **Flexibility:**
  - Early repayment with interest to date.
  - Auto-rollover into the next auction.
  - A fixed-price **note marketplace** so lenders can exit early.

> Not affiliated with or endorsed by Robinhood. "Robinhood Chain" is only the name of the network this protocol runs on.

## Mainnet deployment (Robinhood Chain, 4663)

Deployed 2026-10-09. Admin of every contract is the 48h Timelock; the deployer has renounced admin. Source is verified on [Sourcify](https://sourcify.dev) (chain 4663). Full list: [deployments/4663.json](deployments/4663.json).

| Contract | Address |
|---|---|
| AuctionHouse | [`0xD5FC53bC7772B9AD1b2d3dfe95397c9369Dbc739`](https://robinhoodchain.blockscout.com/address/0xD5FC53bC7772B9AD1b2d3dfe95397c9369Dbc739) |
| TermRegistry | [`0x92F6cD65752ae06c5d7fb0311d09fBA309081D74`](https://robinhoodchain.blockscout.com/address/0x92F6cD65752ae06c5d7fb0311d09fBA309081D74) |
| RepoLocker | [`0xFf6d1d433295faB8c6A62124e755cB93cD00F45b`](https://robinhoodchain.blockscout.com/address/0xFf6d1d433295faB8c6A62124e755cB93cD00F45b) |
| RepoNote | [`0x9Df26E8eb8956A800029eDde18553CE11685dD64`](https://robinhoodchain.blockscout.com/address/0x9Df26E8eb8956A800029eDde18553CE11685dD64) |
| MarginEngine | [`0x0cCF30C9B5F3635aE123b679854eaE82D92806CA`](https://robinhoodchain.blockscout.com/address/0x0cCF30C9B5F3635aE123b679854eaE82D92806CA) |
| Liquidator | [`0x15B038a3aa78fa0Adcd65D7e380B5c3e3211b989`](https://robinhoodchain.blockscout.com/address/0x15B038a3aa78fa0Adcd65D7e380B5c3e3211b989) |
| NoteMarket | [`0xf57E9fb6a7d6890863b1d72BF6F33BFF40E4C4f9`](https://robinhoodchain.blockscout.com/address/0xf57E9fb6a7d6890863b1d72BF6F33BFF40E4C4f9) |
| MarketClock | [`0x129f07E15e780528bA4E8FaeB76B1f25CF7AE03a`](https://robinhoodchain.blockscout.com/address/0x129f07E15e780528bA4E8FaeB76B1f25CF7AE03a) |
| OracleAdapter | [`0xeDb013811f8c399ADD6fD5c867a536678De99999`](https://robinhoodchain.blockscout.com/address/0xeDb013811f8c399ADD6fD5c867a536678De99999) |
| FeeCollector | [`0x8FE27C8f7c08011d940612968F768624A875b0D5`](https://robinhoodchain.blockscout.com/address/0x8FE27C8f7c08011d940612968F768624A875b0D5) |
| ProjectTokenHooks | [`0x0d6fdD1E5E8dB7C18Dd4203107cb27866dA793F3`](https://robinhoodchain.blockscout.com/address/0x0d6fdD1E5E8dB7C18Dd4203107cb27866dA793F3) |
| ComplianceRegistry | [`0x3fE1b810F121Cb924Fa0f303451ABB3df0F2773b`](https://robinhoodchain.blockscout.com/address/0x3fE1b810F121Cb924Fa0f303451ABB3df0F2773b) |
| Timelock | [`0x4bBE55070bb883FcF774BF6Dc40301cD78e76F02`](https://robinhoodchain.blockscout.com/address/0x4bBE55070bb883FcF774BF6Dc40301cD78e76F02) |
| ClearingLib (library) | [`0xb5ba3e949805a5F8366495110D2EaacED4cC78bE`](https://robinhoodchain.blockscout.com/address/0xb5ba3e949805a5F8366495110D2EaacED4cC78bE) |

## Repository layout

```
contracts/   Foundry (Solidity 0.8.28, OpenZeppelin v5)
  src/core/        AuctionHouse, TermRegistry, RepoLocker, RepoNote, MarginEngine, Liquidator, MarketClock
  src/oracle/      OracleAdapter (swappable), PushPriceFeed (fallback feed)
  src/periphery/   NoteMarket, FeeCollector, ProjectTokenHooks, ComplianceRegistry, OvernightTimelock
  src/libraries/   ClearingLib (uniform-price clearing), RepoMath
  script/          Deploy.s.sol (one-shot deploy), ProtocolDeployer.sol (shared wiring, also used by tests)
  test/            unit / fuzz / invariant / fork
  config/          deploy.4663.json (assets, feeds, haircuts, cadence)
app/         Next.js + wagmi/viem + RainbowKit frontend
scripts/     keeper (TypeScript/viem) + ABI export
config/      chains.ts (chain facts with source links; re-exports the deploy config)
deployments/ <chainId>.json written by the deploy script
docs/        architecture notes
```

## How it works

```
 lender ──commitLend(amount, H(rate,salt))──┐                       ┌── RepoNote (ERC-1155) ──► lender
                                            ▼                       │
                                     AuctionHouse ──clear()──► RepoLocker ◄── repay / top-up ── borrower
                                            ▲         uniform rate  │  ▲
 borrower ─commitBorrow(amt, coll, H(..))───┘                       │  └── MarginEngine.poke (keeper)
                                                                    ▼             │
                                                         series cash → redeem     ▼
                                                                             Liquidator (Dutch)
```

1. **Commit** (18h): escrow USDG (lenders) or collateral (borrowers) together with a hash of the rate.
2. **Reveal** (2h): open the rate. Commitments never revealed forfeit 1%.
3. **Clear** (anyone, within 24h): the volume-maximising rate is found, and the clearing rate is the midpoint of the marginal lender and borrower rates. The long side is rationed pro-rata. If nobody clears, every order becomes fully refundable.
4. **Settle** (per order, pull-based): lenders get notes, borrowers get proceeds net of the 0.25%/yr fee, and leftovers are refunded or rolled.
5. **During the repo:** keepers poke margins. Below maintenance triggers a margin call with 4h of grace, then a Dutch auction. A gap past debt + penalty triggers an immediate auction.
6. **At maturity:** the borrower repays (or auto-rolls). Once every repo in a series is closed, noteholders redeem pro-rata.

## Chain

Robinhood Chain mainnet, chain ID **4663**, gas token ETH, explorer https://robinhoodchain.blockscout.com.

| Item | Value |
|---|---|
| Stablecoin | **USDG** `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (6 decimals) |
| Launch collateral | TSLA, AAPL, NVDA, SPY, AMZN, MSFT, GOOGL (18-decimal stock tokens) |
| Oracles | Chainlink per-stock feeds |

All addresses were verified on-chain; sources are in [config/chains.ts](config/chains.ts) and [contracts/config/deploy.4663.json](contracts/config/deploy.4663.json). Known gaps (no sequencer-uptime feed, no second oracle, no native USDC) are covered by swappable adapters and documented in [DECISIONS.md](DECISIONS.md).

## Quick start

```bash
pnpm install
cd contracts && forge build && forge test --no-match-path "test/fork/*"
```

Fork tests run against the live chain (set `ROBINHOOD_RPC_URL` to a provider for reliability):

```bash
cd contracts && forge test --match-path "test/fork/*" -vv
```

Coverage on core contracts:

```bash
cd contracts && forge coverage --report summary --no-match-coverage "(test|script)/" --no-match-path "test/fork/*"
```

Regenerate ABIs for the app and keeper after a contract change:

```bash
pnpm abis
```

Frontend:

```bash
pnpm --filter app dev
```

## Verification status

| Check | Result |
|---|---|
| Unit + fuzz + invariant tests | **92 passing** (fuzz: 512 runs; 4 invariants over 48 runs × 40 depth) |
| Fork tests (Robinhood mainnet, real USDG / TSLA / AAPL / Chainlink) | **3 passing** |
| Slither 0.11.6 | **0 High / 0 Medium** (justified suppressions listed in THREAT_MODEL.md) |
| Full deploy on a local anvil fork of mainnet | **success**: 13 contracts + library, 28 books, admin handed to the Timelock |
| Mainnet dry run (`forge script` without `--broadcast`) | **success**: ~34.8M gas |
| Line coverage | **99%+ total**, every contract ≥ 97% (table below) |

| Contract | Lines | Branches |
|---|---|---|
| AuctionHouse | 100% | 92.7% |
| ClearingLib | 100% | 95.5% |
| RepoLocker | 97.3% | 95.2% |
| MarginEngine | 98.6% | 100% |
| Liquidator | 100% | 90.5% |
| TermRegistry | 100% | 95.8% |
| MarketClock | 100% | 70% |
| RepoNote | 100% | n/a |
| OracleAdapter | 100% | 94.4% |
| PushPriceFeed | 100% | 83.3% |
| NoteMarket | 100% | 93.8% |
| FeeCollector | 100% | 100% |
| ProjectTokenHooks | 100% | 95% |
| ComplianceRegistry | 100% | 100% |
| OvernightTimelock | 100% | 100% |

## Documents

- [DEPLOY.md](DEPLOY.md): the exact commands to deploy, verify, wire the token, run the keeper and ship the app.
- [DECISIONS.md](DECISIONS.md): every product and technical decision, with reasons.
- [THREAT_MODEL.md](THREAT_MODEL.md): assets, actors, top risks (bid shading, reveal griefing, market-open gaps, keeper failure) and mitigations.
- [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md): how $OVND plugs in (no token is deployed here).
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): contract-by-contract reference.
- [app/README.md](app/README.md): frontend details.

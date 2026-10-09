# DEPLOY

Everything below is run by you. No private key or seed phrase is ever written to disk in plain text, echoed or committed: signing happens only through Foundry's encrypted keystores.

**Prerequisites:**
- Foundry ≥ 1.8 (`foundryup`), Node 22+, pnpm 9.
- Some ETH on Robinhood Chain for gas. A full deploy simulated at about 34.8M gas, roughly 0.0015 ETH at current fees.
- **Recommended:** a dedicated RPC endpoint (Alchemy, Chainstack or QuickNode). The public RPC is rate-limited and "not for production use".

```bash
export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com   # or your provider URL
```

Optional role addresses. Each defaults to the deployer. **For production, set them to a multisig.**

```bash
export TIMELOCK_PROPOSER=0xYourMultisig   # proposes + executes Timelock operations (48h delay)
export GUARDIAN=0xYourOpsKey              # pause/unpause + compliance allowlist manager
export TREASURY=0xYourTreasury            # fee recipient
```

## 1. Import the deployer key into an encrypted Foundry keystore (once)

```bash
cast wallet import overnightdesk-deployer --interactive
```

Paste the key when prompted and choose a password. It is stored encrypted in `~/.foundry/keystores/overnightdesk-deployer`.

## 2. Deploy, wire, hand admin to the Timelock, and verify (one command)

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url $ROBINHOOD_RPC_URL --account overnightdesk-deployer --sender $(cast wallet address --account overnightdesk-deployer) --broadcast --slow --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

What it does:
- Deploys 13 contracts plus the `ClearingLib` library.
- Configures 4 terms (overnight, 7D, 30D, 90D) and 7 collateral stocks with their Chainlink feeds, giving 28 books.
- Sets the 24/5 market-hours window.
- Grants `DEFAULT_ADMIN_ROLE` on every contract to the 48h `OvernightTimelock`, and the deployer renounces it. This is checked on-chain in `_postflight`.
- Verifies all contracts on Blockscout.
- Writes `deployments/4663.json` (keeper) and `app/public/deployments/4663.json` (frontend). Commit both.

If verification is interrupted (for example by the Blockscout rate limit), re-run the verification only:

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url $ROBINHOOD_RPC_URL --account overnightdesk-deployer --sender $(cast wallet address --account overnightdesk-deployer) --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

**Dry run first (no signing, nothing sent).** This simulates against live mainnet state; output goes to `deployments/4663.dryrun.json`.

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url $ROBINHOOD_RPC_URL --sender $(cast wallet address --account overnightdesk-deployer)
```


> **Verification note:** the Blockscout API is behind a Cloudflare bot challenge that blocks CLI clients, so `--verify --verifier blockscout` does nothing. Verify on Sourcify instead (Blockscout imports from it). Run this per contract from `contracts/`; AuctionHouse needs `--libraries src/libraries/ClearingLib.sol:ClearingLib:<lib address>`:
> `forge verify-contract <address> src/core/AuctionHouse.sol:AuctionHouse --chain-id 4663 --verifier sourcify --libraries src/libraries/ClearingLib.sol:ClearingLib:<lib>`

## 3. Later: wire the $OVND token (after it launches)

This goes through the 48h Timelock and is sent by the `TIMELOCK_PROPOSER`. Shown here with the deployer keystore, which is the proposer if you didn't override it. See TOKEN_INTEGRATION.md for details.

```bash
TIMELOCK=$(jq -r .Timelock deployments/4663.json); HOOKS=$(jq -r .ProjectTokenHooks deployments/4663.json); OVND=0xTokenAddress; DATA=$(cast calldata "setProjectToken(address)" $OVND); SALT=$(cast keccak set-ovnd); ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
```

```bash
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $DATA $ZERO $SALT 172800 --account overnightdesk-deployer --rpc-url $ROBINHOOD_RPC_URL
```

After 48 hours:

```bash
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" $HOOKS 0 $DATA $ZERO $SALT --account overnightdesk-deployer --rpc-url $ROBINHOOD_RPC_URL
```

Then set `NEXT_PUBLIC_PROJECT_TOKEN=$OVND` in Vercel and redeploy the app.

## 4. Start the keeper

The keeper clears auctions, submits auto-rolls, pokes margins, restarts liquidation auctions and distributes fees. Every action is permissionless, so you can (and should) run more than one keeper.

Create its keystore once:

```bash
cast wallet import overnightdesk-keeper --interactive
```

Fund the keeper address with a little ETH:

```bash
cast wallet address --account overnightdesk-keeper
```

Then start it:

```bash
pnpm install && KEEPER_RPC_URL=$ROBINHOOD_RPC_URL pnpm keeper
```

- It prompts once for the keystore password; the key is decrypted only in memory.
- For unattended runs, set `KEEPER_PASSWORD_FILE` to a `chmod 600` file outside the repo.
- Use `KEEPER_DRY_RUN=1` to simulate without sending.
- All options are in `scripts/.env.example`.
- Run it under a process supervisor (systemd, pm2 or Docker) with restart-on-failure.

## 5. Deploy the frontend to Vercel

1. Push the repo to GitHub (including `app/public/deployments/4663.json`).
2. In Vercel, choose **New Project → Import**:

| Setting | Value |
|---|---|
| Root Directory | `app` |
| Install command | `pnpm install` |
| Build command | `pnpm build` |
| Framework | Next.js |

3. Set these environment variables:

| Variable | Value |
|---|---|
| `NEXT_PUBLIC_CHAIN_ID` | `4663` |
| `NEXT_PUBLIC_RPC_URL` | your provider URL (optional) |
| `NEXT_PUBLIC_WC_PROJECT_ID` | WalletConnect project ID (optional; empty = injected wallets only) |
| `NEXT_PUBLIC_PROJECT_TOKEN` | empty until $OVND is wired |
| `NEXT_PUBLIC_GEOBLOCK_COUNTRIES` | optional, e.g. `US,CA,GB,CH` |

4. Deploy. Or from the CLI:

```bash
cd app && npx vercel --prod
```

## Post-deploy checklist

- `cast call <AuctionHouse> "hasRole(bytes32,address)(bool)" 0x00…00 <Timelock>` should return `true`. The same call with the deployer address should return `false`.
- The guardian can pause: `cast send <contract> "pause()" --account <guardian>`.
- Keeper logs show `tick epoch=…`.
- Optionally, enable compliance: a Timelock `ComplianceRegistry.setEnabled(true)`, then the guardian calls `setAllowed([...], true)`.

## Local proof (already run)

**Anvil fork of mainnet** (chain ID overridden to 31337), signed by anvil's unlocked dev account:

```bash
anvil --fork-url $ROBINHOOD_RPC_URL --chain-id 31337 --port 8571
```

Run the deploy against it straight away, because the public RPC only serves recent state:

```bash
cd contracts && DEPLOY_CONFIG=4663 forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8571 --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --unlocked --broadcast
```

The keeper against the fork:

```bash
KEEPER_RPC_URL=http://127.0.0.1:8571 KEEPER_UNLOCKED_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 pnpm keeper
```

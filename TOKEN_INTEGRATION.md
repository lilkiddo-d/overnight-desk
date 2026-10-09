# $OVND token integration

**This repository does not create or deploy any ERC-20.** The project token ($OVND) launches separately on a launchpad. Overnight Desk works fully without it. The only ERC-20 in the code base is a test mock under `contracts/test/utils/Mocks.sol`, which is never deployed.

## Where the token plugs in

All token logic lives in one contract, `ProjectTokenHooks` (`contracts/src/periphery/ProjectTokenHooks.sol`).

| Feature | How it works | Before the token is set |
|---|---|---|
| Fee sharing | `FeeCollector.distribute()` sends `stakerShareBps` (default 50%) of stablecoin fees to `ProjectTokenHooks`; stakers earn them pro-rata via an accumulator and call `claimRewards()` | 100% of fees go to the treasury |
| Fee discount tier | `AuctionHouse` asks `hooks.feeDiscountBps(borrower)` at clearing. Stakers holding at least `tierThreshold` for at least `minStakeAge` (default 3 days) get `discountBps` off the auction fee (max 50%). | Discount is always 0 |
| Staking | `stake`, `requestUnstake` (starts a 7-day cooldown), `withdraw` | `stake` reverts with `TokenNotSet` |

Anti-gaming: the stake-age requirement and unstake cooldown stop flash-staking around a fee distribution or an auction. Rewards that arrive while nobody is staked are carried into the next distribution.

## Activating the token (after launch)

`setProjectToken(address)` can be called **exactly once**, only by `DEFAULT_ADMIN_ROLE`, which is the 48h Timelock. It rejects the zero address and addresses without code. The steps:

```bash
# addresses from deployments/4663.json
TIMELOCK=<Timelock>
HOOKS=<ProjectTokenHooks>
OVND=<launched token address>
DATA=$(cast calldata "setProjectToken(address)" $OVND)
SALT=$(cast keccak "set-ovnd")

# 1) schedule (proposer = TIMELOCK_PROPOSER / multisig)
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT 172800 \
  --account overnightdesk-deployer --rpc-url $ROBINHOOD_RPC_URL

# 2) after 48h, execute
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
  $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT \
  --account overnightdesk-deployer --rpc-url $ROBINHOOD_RPC_URL
```

Optionally schedule `setTier(threshold, discountBps, minStakeAge)` in the same way. The tier is off until `tierThreshold > 0`.

If the proposer is a multisig (recommended), submit the same `schedule` and `execute` calls from the multisig UI instead of `cast send`.

## Frontend

- `NEXT_PUBLIC_PROJECT_TOKEN`: set it to the token address once `setProjectToken` has executed.
- If it's empty, all token UI (the Stake page and tier badges) is hidden.
- The app also checks `ProjectTokenHooks.isActive()` on-chain before showing staking.

## Tests

`contracts/test/unit/Periphery.t.sol` (`TokenAndFeesTest`, `GovernanceTest`) and `AuctionHouse.t.sol::test_feeDiscountForStakers` cover these paths with a **mock** ERC-20:
- disabled-until-set
- one-shot set
- the Timelock path (schedule, then execute after 48h)
- rewards accounting
- cooldown
- discount tier

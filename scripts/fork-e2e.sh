#!/usr/bin/env bash
# End-to-end proof on a LOCAL anvil fork of Robinhood Chain mainnet.
#   1) start the fork in another terminal (chain id 31337 so wallets never confuse it with mainnet):
#        anvil --fork-url $ROBINHOOD_RPC_URL --chain-id 31337 --port 8571
#   2) run this script right away (the public RPC only serves recent state):
#        bash scripts/fork-e2e.sh
# Signs only with anvil's unlocked dev accounts (--unlocked); no private keys are used or printed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${FORK_RPC:-http://127.0.0.1:8571}"
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil dev account #0 (public test account)
CAST="cast"; command -v cast >/dev/null 2>&1 || CAST="cast.exe"

USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
TSLA=0x322F0929c4625eD5bAd873c95208D54E1c003b2d
# balanceOf storage slots for anvil dev accounts #1/#2/#3 (found with forge-std stdstore: test/fork/BalanceSlots.t.sol)
USDG_SLOT_A1=0x3c8e904cdb19937d60d41c8d984b1a8803ad6e0891b4f9e032dcec2a22c2c7f5
USDG_SLOT_A3=0xb7a6405fe2217253295ac09a8724c38c054f1550bde8f10fdfe324527bb528b9
USDG_SLOT_A2=0x0b083aff9656985dfe31da85d804ae48751ca629d18248f32ff52e77f5a2fb2b
TSLA_SLOT_A2=0x3e32d9229f487258901cc15b775c2e11b304154abcf4dc76dfbf780b6c4601c8

[ "$($CAST chain-id --rpc-url "$RPC")" = "31337" ] || { echo "not the local fork"; exit 1; }

echo "== deploy"
(cd "$ROOT/contracts" && DEPLOY_CONFIG=4663 forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --sender $DEPLOYER --unlocked --broadcast >/dev/null)
CLOCK=$(cd "$ROOT" && node -p "require('./deployments/31337.json').MarketClock")

echo "== fund test accounts"
amt() { $CAST to-uint256 "$1"; }
$CAST rpc anvil_setStorageAt $USDG $USDG_SLOT_A1 "$(amt 1000000000000)" --rpc-url "$RPC" >/dev/null # 1,000,000 USDG
$CAST rpc anvil_setStorageAt $USDG $USDG_SLOT_A3 "$(amt 1000000000000)" --rpc-url "$RPC" >/dev/null
$CAST rpc anvil_setStorageAt $USDG $USDG_SLOT_A2 "$(amt 1000000000000)" --rpc-url "$RPC" >/dev/null
$CAST rpc anvil_setStorageAt $TSLA $TSLA_SLOT_A2 "$(amt 1000000000000000000000)" --rpc-url "$RPC" >/dev/null # 1,000 TSLA
# The public anvil dev accounts carry EIP-7702 delegation code on the real chain (their keys are public), which makes
# ERC-1155 receiver checks revert. Strip it on the fork so they behave like plain EOAs.
for a in 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906; do
  $CAST rpc anvil_setCode $a 0x --rpc-url "$RPC" >/dev/null
done

warp_to() { $CAST rpc evm_setNextBlockTimestamp "$1" --rpc-url "$RPC" >/dev/null; $CAST rpc evm_mine --rpc-url "$RPC" >/dev/null; }
EPOCH=$($CAST call $CLOCK "currentEpoch()(uint64)" --rpc-url "$RPC")
echo "== commit (epoch $EPOCH)"
(cd "$ROOT/contracts" && PHASE=commit forge script script/ForkScenario.s.sol:ForkScenario --rpc-url "$RPC" --unlocked --sender $DEPLOYER --broadcast >/dev/null)
warp_to "$($CAST call $CLOCK "commitEnd(uint64)(uint64)" $EPOCH --rpc-url "$RPC" | cut -d' ' -f1)"
echo "== reveal"
(cd "$ROOT/contracts" && PHASE=reveal forge script script/ForkScenario.s.sol:ForkScenario --rpc-url "$RPC" --unlocked --sender $DEPLOYER --broadcast >/dev/null)
warp_to "$($CAST call $CLOCK "revealEnd(uint64)(uint64)" $EPOCH --rpc-url "$RPC" | cut -d' ' -f1)"
echo "== keeper clears"
(cd "$ROOT/scripts" && KEEPER_RPC_URL="$RPC" KEEPER_UNLOCKED_ADDRESS=$DEPLOYER npx tsx src/keeper.ts --once)
echo "== settle + list notes"
J="$ROOT/deployments/31337.json"
AH=$(cd "$ROOT" && node -p "require('./deployments/31337.json').AuctionHouse")
NM=$(cd "$ROOT" && node -p "require('./deployments/31337.json').NoteMarket")
NOTE=$(cd "$ROOT" && node -p "require('./deployments/31337.json').RepoNote")
for who in 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 0x90F79bf6EB2c4f870365E785982E1f101E93b906 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; do
  for id in $($CAST call $AH "ordersOf(address)(uint256[])" $who --rpc-url "$RPC" | tr -d '[],'); do
    $CAST send $AH "settle(uint256)" $id --from $who --unlocked --rpc-url "$RPC" >/dev/null && echo "settled order $id"
  done
done
L1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
echo "lender notes (7D series 2): $($CAST call $NOTE "balanceOf(address,uint256)(uint256)" $L1 2 --rpc-url "$RPC")"
$CAST send $NOTE "setApprovalForAll(address,bool)" $NM true --from $L1 --unlocked --rpc-url "$RPC" >/dev/null
$CAST send $NM "list(uint256,uint256,uint256)" 2 5000000000 998000000000000000 --from $L1 --unlocked --rpc-url "$RPC" >/dev/null && echo "listed 5,000 notes @ 0.998"
for b in 0 1 2; do echo "book $b: $($CAST call $AH "getResult(uint32,uint64)((bool,uint32,uint64,uint128,uint256))" $b $EPOCH --rpc-url "$RPC")"; done
echo "== done"

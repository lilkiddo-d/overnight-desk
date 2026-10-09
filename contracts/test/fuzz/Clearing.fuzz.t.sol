// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClearingLib} from "../../src/libraries/ClearingLib.sol";
import {RepoMath} from "../../src/libraries/RepoMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ClearingFuzzTest is Test {
    function _build(uint256 seed, uint256 n, bool lend)
        internal
        pure
        returns (uint256[] memory rates, uint256[] memory amts)
    {
        rates = new uint256[](n);
        amts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i, lend)));
            // coarse rate grid to force ties (pro-rata tiers)
            rates[i] = 1 + (h % 40) * 25;
            amts[i] = 100e6 + ((h >> 64) % 1_000_000e6);
            if ((h >> 200) % 11 == 0) amts[i] = 0; // excluded / invalid orders
        }
    }

    function testFuzz_clearingProperties(uint256 seed, uint8 nl, uint8 nb) public pure {
        uint256 n = bound(nl, 0, 64);
        uint256 m = bound(nb, 0, 64);
        (uint256[] memory lR, uint256[] memory lA) = _build(seed, n, true);
        (uint256[] memory bR, uint256[] memory bA) = _build(seed, m, false);
        ClearingLib.Result memory r = ClearingLib.clear(lR, lA, bR, bA);

        uint256 sl;
        uint256 sb;
        for (uint256 i; i < n; ++i) {
            assertLe(r.lendFills[i], lA[i], "lender overfilled");
            if (r.lendFills[i] > 0) {
                assertLe(lR[i], r.rateBps, "lender limit violated");
                // strictly better-priced lenders are fully filled
                for (uint256 k; k < n; ++k) {
                    if (lR[k] < lR[i]) assertEq(r.lendFills[k], lA[k], "lender priority");
                }
            }
            sl += r.lendFills[i];
        }
        for (uint256 j; j < m; ++j) {
            assertLe(r.borrowFills[j], bA[j], "borrower overfilled");
            if (r.borrowFills[j] > 0) {
                assertGe(bR[j], r.rateBps, "borrower limit violated");
                for (uint256 k; k < m; ++k) {
                    if (bR[k] > bR[j]) assertEq(r.borrowFills[k], bA[k], "borrower priority");
                }
            }
            sb += r.borrowFills[j];
        }
        assertEq(sl, r.volume, "lend volume");
        assertEq(sb, r.volume, "borrow volume");

        // volume is maximal over every uniform rate
        for (uint256 k; k < n + m; ++k) {
            uint256 c = k < n ? lR[k] : bR[k - n];
            uint256 s;
            uint256 dd;
            for (uint256 i; i < n; ++i) {
                if (lR[i] <= c) s += lA[i];
            }
            for (uint256 j; j < m; ++j) {
                if (bR[j] >= c) dd += bA[j];
            }
            assertLe(Math.min(s, dd), r.volume, "not volume maximising");
        }
    }

    function testFuzz_singleCross(uint32 lr, uint32 br, uint96 la, uint96 ba) public pure {
        lr = uint32(bound(lr, 1, 5_000));
        br = uint32(bound(br, 1, 5_000));
        la = uint96(bound(la, 1, type(uint96).max));
        ba = uint96(bound(ba, 1, type(uint96).max));
        uint256[] memory lR = new uint256[](1);
        uint256[] memory lA = new uint256[](1);
        uint256[] memory bR = new uint256[](1);
        uint256[] memory bA = new uint256[](1);
        lR[0] = lr;
        lA[0] = la;
        bR[0] = br;
        bA[0] = ba;
        ClearingLib.Result memory r = ClearingLib.clear(lR, lA, bR, bA);
        if (lr <= br) {
            assertEq(r.volume, Math.min(la, ba));
            assertEq(r.rateBps, (uint256(lr) + br) / 2);
        } else {
            assertEq(r.volume, 0);
        }
    }

    function testFuzz_interestRoundsUp(uint128 p, uint32 rate, uint32 dt) public pure {
        rate = uint32(bound(rate, 0, 100_000));
        dt = uint32(bound(dt, 0, 400 days));
        uint256 exactNum = uint256(p) * rate * dt;
        uint256 i = RepoMath.interest(p, rate, dt);
        assertGe(i * 10_000 * 365 days, exactNum);
        assertLt(i * 10_000 * 365 days, exactNum + 10_000 * 365 days);
    }

    function testFuzz_feeDiscountMonotone(uint128 p, uint16 fee, uint32 dur, uint16 disc) public pure {
        fee = uint16(bound(fee, 0, 500));
        dur = uint32(bound(dur, 1 hours, 400 days));
        disc = uint16(bound(disc, 0, 10_000));
        uint256 full = RepoMath.fee(p, fee, dur, 0);
        uint256 discounted = RepoMath.fee(p, fee, dur, disc);
        assertLe(discounted, full);
        assertEq(RepoMath.fee(p, fee, dur, 10_000), 0);
    }

    function testFuzz_valueCollateralRoundTrip(uint96 stableAmt, uint64 priceUsd) public pure {
        uint256 price = bound(priceUsd, 1, 100_000) * 1e18;
        uint256 coll = RepoMath.collateralFor(stableAmt, 18, price, 6);
        assertGe(RepoMath.value(coll, 18, price, 6, Math.Rounding.Ceil), stableAmt);
    }
}

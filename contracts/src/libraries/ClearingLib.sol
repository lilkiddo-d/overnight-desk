// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ClearingLib
/// @notice Uniform-price (single clearing rate) matching for one sealed-bid batch auction.
/// @dev Lenders offer principal at a MINIMUM rate, borrowers bid for principal at a MAXIMUM rate.
///      1. The volume-maximising rate r* is found among all submitted rates (ties -> lowest rate).
///      2. Matched lenders: rate <= r*. Matched borrowers: rate >= r*.
///      3. Clearing rate = midpoint of the marginal (highest) matched lender rate and the marginal
///         (lowest) matched borrower rate, so every matched order's limit is satisfied.
///      4. The short side fills completely. The long side fills by rate priority; the marginal tier is
///         rationed pro-rata and rounding dust is handed out one unit at a time, so both sides sum to the
///         same volume exactly and no order is over-filled.
///      Complexity is O((n+m)^2) with n, m bounded by the per-side order cap (<= 64).
library ClearingLib {
    struct Result {
        uint256 rateBps;
        uint256 volume;
        uint256[] lendFills;
        uint256[] borrowFills;
    }

    function clear(uint256[] memory lRates, uint256[] memory lAmts, uint256[] memory bRates, uint256[] memory bAmts)
        public
        pure
        returns (Result memory res)
    {
        res.lendFills = new uint256[](lRates.length);
        res.borrowFills = new uint256[](bRates.length);
        if (lRates.length == 0 || bRates.length == 0) return res;

        (uint256 rStar, uint256 vol) = _bestRate(lRates, lAmts, bRates, bAmts);
        if (vol == 0) return res;

        uint256 lMax = 0;
        uint256 bMin = type(uint256).max;
        uint256 supply = 0;
        uint256 demand = 0;
        bool[] memory lElig = new bool[](lRates.length);
        bool[] memory bElig = new bool[](bRates.length);
        for (uint256 i; i < lRates.length; ++i) {
            if (lRates[i] <= rStar && lAmts[i] > 0) {
                lElig[i] = true;
                supply += lAmts[i];
                if (lRates[i] > lMax) lMax = lRates[i];
            }
        }
        for (uint256 j; j < bRates.length; ++j) {
            if (bRates[j] >= rStar && bAmts[j] > 0) {
                bElig[j] = true;
                demand += bAmts[j];
                if (bRates[j] < bMin) bMin = bRates[j];
            }
        }

        res.volume = vol;
        res.rateBps = (lMax + bMin) / 2;
        res.lendFills = _allocate(lRates, lAmts, lElig, vol, supply, true);
        res.borrowFills = _allocate(bRates, bAmts, bElig, vol, demand, false);
    }

    function _bestRate(uint256[] memory lRates, uint256[] memory lAmts, uint256[] memory bRates, uint256[] memory bAmts)
        private
        pure
        returns (uint256 bestRate, uint256 bestVol)
    {
        uint256 n = lRates.length;
        uint256 m = bRates.length;
        for (uint256 k; k < n + m; ++k) {
            uint256 c = k < n ? lRates[k] : bRates[k - n];
            uint256 s = 0;
            uint256 d = 0;
            for (uint256 i; i < n; ++i) {
                if (lRates[i] <= c) s += lAmts[i];
            }
            for (uint256 j; j < m; ++j) {
                if (bRates[j] >= c) d += bAmts[j];
            }
            uint256 v = s < d ? s : d;
            if (v > bestVol || (v == bestVol && v > 0 && c < bestRate)) {
                bestVol = v;
                bestRate = c;
            }
        }
    }

    /// @dev Fill eligible orders up to `vol` by rate priority (ascending for lenders, descending for borrowers).
    function _allocate(
        uint256[] memory rates,
        uint256[] memory amts,
        bool[] memory elig,
        uint256 vol,
        uint256 total,
        bool ascending
    ) private pure returns (uint256[] memory fills) {
        uint256 len = rates.length;
        fills = new uint256[](len);
        if (total <= vol) {
            for (uint256 i; i < len; ++i) {
                if (elig[i]) fills[i] = amts[i];
            }
            return fills;
        }

        // Collect eligible indices and insertion-sort them by priority (stable: earlier orders first).
        uint256[] memory idx = new uint256[](len);
        uint256 cnt = 0;
        for (uint256 i; i < len; ++i) {
            if (elig[i]) idx[cnt++] = i;
        }
        for (uint256 i = 1; i < cnt; ++i) {
            uint256 cur = idx[i];
            uint256 j = i;
            while (j > 0 && _before(rates[cur], rates[idx[j - 1]], ascending)) {
                idx[j] = idx[j - 1];
                --j;
            }
            idx[j] = cur;
        }

        _fillTiers(rates, amts, idx, cnt, vol, fills);
    }

    function _fillTiers(
        uint256[] memory rates,
        uint256[] memory amts,
        uint256[] memory idx,
        uint256 cnt,
        uint256 vol,
        uint256[] memory fills
    ) private pure {
        uint256 cum = 0;
        uint256 p = 0;
        while (p < cnt) {
            uint256 tierRate = rates[idx[p]];
            uint256 q = p;
            uint256 tierTotal;
            while (q < cnt && rates[idx[q]] == tierRate) {
                tierTotal += amts[idx[q]];
                ++q;
            }
            if (cum + tierTotal <= vol) {
                for (uint256 t = p; t < q; ++t) {
                    fills[idx[t]] = amts[idx[t]];
                }
                cum += tierTotal;
                if (cum == vol) return;
            } else {
                _prorata(amts, idx, p, q, vol - cum, tierTotal, fills);
                return;
            }
            p = q;
        }
    }

    /// @dev Ration `rem` (< tierTotal) across idx[p..q) pro-rata. Each floor share is strictly below the order
    ///      amount, and the dust (< q - p) is handed out one unit at a time, so no order is ever over-filled.
    function _prorata(
        uint256[] memory amts,
        uint256[] memory idx,
        uint256 p,
        uint256 q,
        uint256 rem,
        uint256 tierTotal,
        uint256[] memory fills
    ) private pure {
        uint256 given = 0;
        for (uint256 t = p; t < q; ++t) {
            uint256 f = (amts[idx[t]] * rem) / tierTotal;
            fills[idx[t]] = f;
            given += f;
        }
        uint256 dust = rem - given;
        for (uint256 t = p; t < q && dust > 0; ++t) {
            if (fills[idx[t]] < amts[idx[t]]) {
                ++fills[idx[t]];
                --dust;
            }
        }
    }

    function _before(uint256 a, uint256 b, bool ascending) private pure returns (bool) {
        return ascending ? a < b : a > b;
    }
}

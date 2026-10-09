// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RepoMath
/// @notice Fixed-rate simple-interest and valuation helpers. Rates are annual, in basis points, ACT/365.
library RepoMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    /// @notice Simple interest on `principal` for `elapsed` seconds at `rateBps`, rounded up (in favour of lenders).
    function interest(uint256 principal, uint256 rateBps, uint256 elapsed) internal pure returns (uint256) {
        return Math.mulDiv(principal, rateBps * elapsed, BPS * YEAR, Math.Rounding.Ceil);
    }

    /// @notice Annualised fee on `principal` for a term of `duration` seconds, after `discountBps`. Rounded down.
    function fee(uint256 principal, uint256 feeBpsPerYear, uint256 duration, uint256 discountBps)
        internal
        pure
        returns (uint256)
    {
        if (discountBps >= BPS) return 0;
        uint256 gross = Math.mulDiv(principal, feeBpsPerYear * duration, BPS * YEAR);
        return Math.mulDiv(gross, BPS - discountBps, BPS);
    }

    /// @notice Value of `amount` collateral (with `collDecimals`) priced at `priceE18` USD per whole token,
    ///         expressed in stablecoin units (`stableDecimals`).
    function value(uint256 amount, uint8 collDecimals, uint256 priceE18, uint8 stableDecimals, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(amount * priceE18, 10 ** stableDecimals, (10 ** collDecimals) * 1e18, rounding);
    }

    /// @notice Collateral amount worth `stableAmount` at `priceE18`, rounded up.
    function collateralFor(uint256 stableAmount, uint8 collDecimals, uint256 priceE18, uint8 stableDecimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(
            stableAmount, (10 ** collDecimals) * 1e18, priceE18 * (10 ** stableDecimals), Math.Rounding.Ceil
        );
    }

    /// @notice `amount` after removing `haircutBps`.
    function applyHaircut(uint256 amount, uint256 haircutBps) internal pure returns (uint256) {
        return Math.mulDiv(amount, BPS - haircutBps, BPS);
    }
}

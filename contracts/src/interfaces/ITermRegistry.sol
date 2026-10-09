// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITermRegistry {
    struct Term {
        uint32 duration; // seconds
        bool enabled;
        string label;
    }

    struct CollateralConfig {
        bool enabled;
        uint8 decimals;
        uint16 initialHaircutBps; // borrow <= value * (1 - initial)
        uint16 maintenanceHaircutBps; // debt  <= value * (1 - maintenance), else margin call
        uint16 liquidationPenaltyBps; // paid by the borrower on liquidation
        uint128 maxCollateralPerAuction; // per book and auction cap on newly locked collateral (0 = unlimited)
    }

    struct Book {
        uint16 termId;
        address collateral;
        bool enabled;
    }

    struct Params {
        uint128 minOrderSize; // stablecoin units
        uint32 maxRateBps; // max annual rate accepted in an order
        uint16 auctionFeeBpsPerYear; // annualised fee charged to borrowers on matched principal
        uint16 noRevealPenaltyBps; // forfeited by commitments that are never revealed
        uint16 maxOrdersPerSide; // per book and auction (hard capped)
        uint32 marginCallGracePeriod; // seconds a borrower has to cure a margin call
        uint32 maturityGracePeriod; // seconds after maturity before an unpaid repo is liquidatable
    }

    function stablecoin() external view returns (address);
    function stableDecimals() external view returns (uint8);
    function getParams() external view returns (Params memory);
    function getTerm(uint16 termId) external view returns (Term memory);
    function getCollateral(address token) external view returns (CollateralConfig memory);
    function getBook(uint32 bookId) external view returns (Book memory);
    function bookCount() external view returns (uint32);
    function isBookActive(uint32 bookId) external view returns (bool);
    function bookDuration(uint32 bookId) external view returns (uint32);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRepoLocker {
    enum RepoStatus {
        None,
        Active,
        MarginCall,
        Liquidating,
        Closed
    }

    struct Series {
        uint32 bookId;
        uint64 epoch;
        uint32 rateBps;
        uint64 start;
        uint64 maturity;
        uint32 openRepos;
        uint128 principal; // total principal originally lent (== note supply at creation)
        uint128 cash; // stablecoin held for noteholders
        uint128 badDebt; // unrecovered debt written off on liquidation
        uint128 redeemed; // note units already redeemed
    }

    struct Repo {
        address borrower;
        uint32 bookId;
        RepoStatus status;
        bool autoRoll;
        bool rolling;
        uint32 rateBps;
        uint32 autoRollMaxRateBps;
        uint64 start;
        uint64 maturity;
        uint64 marginCallDeadline;
        address collateral;
        uint128 collateralAmount;
        uint128 principal;
        uint256 seriesId;
    }

    function getSeries(uint256 seriesId) external view returns (Series memory);
    function getRepo(uint256 repoId) external view returns (Repo memory);
    function debtOf(uint256 repoId) external view returns (uint256);
    function debtAt(uint256 repoId, uint256 timestamp) external view returns (uint256);

    function createSeries(uint32 bookId, uint64 epoch, uint32 rateBps, uint64 maturity, uint256 principal)
        external
        returns (uint256);
    function openRepo(
        uint256 seriesId,
        address borrower,
        address collateral,
        uint256 collateralAmount,
        uint256 principal
    ) external returns (uint256);
    function executeRoll(uint256 oldRepoId, uint256 newSeriesId, uint256 grossPrincipal, uint256 net, uint256 collMove)
        external
        returns (uint256 newRepoId);
    function setRolling(uint256 repoId, bool rolling) external;

    function setMarginCall(uint256 repoId, uint64 deadline) external;
    function clearMarginCall(uint256 repoId) external;
    function seizeForLiquidation(uint256 repoId)
        external
        returns (address collateral, uint256 collateralAmount, uint256 debt, address borrower);
    function creditLiquidation(uint256 repoId, uint256 amount) external;
    function closeLiquidated(uint256 repoId, uint256 badDebt) external;
}

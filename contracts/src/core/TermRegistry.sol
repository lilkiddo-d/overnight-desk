// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {ITermRegistry} from "../interfaces/ITermRegistry.sol";

/// @title TermRegistry
/// @notice Source of truth for terms (overnight / 7d / 30d / 90d), collateral risk parameters (haircuts) and
///         order books (term x collateral). All mutators are admin (Timelock) only.
contract TermRegistry is ProtocolAccess, ITermRegistry {
    uint16 public constant HARD_MAX_ORDERS_PER_SIDE = 64;
    uint16 public constant MAX_FEE_BPS_PER_YEAR = 500; // 5% p.a.
    uint16 public constant MAX_NO_REVEAL_PENALTY_BPS = 1_000; // 10%
    uint32 public constant MIN_GRACE = 1 hours;
    uint32 public constant MAX_GRACE = 7 days;

    address public immutable override stablecoin;
    uint8 public immutable override stableDecimals;

    Params internal _params;
    Term[] internal _terms;
    Book[] internal _books;
    mapping(address => CollateralConfig) internal _collateral;
    mapping(uint16 => mapping(address => bool)) public bookExists;

    event ParamsUpdated(Params params);
    event TermAdded(uint16 indexed termId, uint32 duration, string label);
    event TermEnabled(uint16 indexed termId, bool enabled);
    event CollateralConfigured(address indexed token, CollateralConfig config);
    event BookAdded(uint32 indexed bookId, uint16 indexed termId, address indexed collateral);
    event BookEnabled(uint32 indexed bookId, bool enabled);

    error UnknownTerm();
    error UnknownBook();
    error DuplicateBook();
    error CollateralNotEnabled();

    constructor(address admin, address stablecoin_, Params memory params_) ProtocolAccess(admin) {
        if (stablecoin_ == address(0)) revert ZeroAddress();
        stablecoin = stablecoin_;
        stableDecimals = IERC20Metadata(stablecoin_).decimals();
        _setParams(params_);
    }

    // ------------------------------------------------------------------ admin

    function setParams(Params calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParams(p);
    }

    function addTerm(uint32 duration, string calldata label) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint16 id) {
        if (duration < 1 hours || duration > 400 days) revert InvalidParam();
        id = uint16(_terms.length);
        _terms.push(Term({duration: duration, enabled: true, label: label}));
        emit TermAdded(id, duration, label);
    }

    function setTermEnabled(uint16 termId, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (termId >= _terms.length) revert UnknownTerm();
        _terms[termId].enabled = enabled;
        emit TermEnabled(termId, enabled);
    }

    function configureCollateral(address token, CollateralConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (cfg.maintenanceHaircutBps == 0 || cfg.maintenanceHaircutBps >= cfg.initialHaircutBps) {
            revert InvalidParam();
        }
        if (cfg.initialHaircutBps >= 9_000) revert InvalidParam();
        if (cfg.liquidationPenaltyBps > 2_000) revert InvalidParam();
        // the penalty must fit inside the maintenance cushion so a margin call can still be fully cured by liquidation
        if (cfg.liquidationPenaltyBps >= cfg.maintenanceHaircutBps) revert InvalidParam();
        CollateralConfig memory c = cfg;
        c.decimals = IERC20Metadata(token).decimals();
        if (c.decimals > 30) revert InvalidParam();
        _collateral[token] = c;
        emit CollateralConfigured(token, c);
    }

    function addBook(uint16 termId, address collateral) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint32 id) {
        if (termId >= _terms.length) revert UnknownTerm();
        if (!_collateral[collateral].enabled) revert CollateralNotEnabled();
        if (bookExists[termId][collateral]) revert DuplicateBook();
        bookExists[termId][collateral] = true;
        id = uint32(_books.length);
        _books.push(Book({termId: termId, collateral: collateral, enabled: true}));
        emit BookAdded(id, termId, collateral);
    }

    function setBookEnabled(uint32 bookId, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bookId >= _books.length) revert UnknownBook();
        _books[bookId].enabled = enabled;
        emit BookEnabled(bookId, enabled);
    }

    // ------------------------------------------------------------------ views

    function getParams() external view override returns (Params memory) {
        return _params;
    }

    function getTerm(uint16 termId) external view override returns (Term memory) {
        if (termId >= _terms.length) revert UnknownTerm();
        return _terms[termId];
    }

    function termCount() external view returns (uint16) {
        return uint16(_terms.length);
    }

    function getCollateral(address token) external view override returns (CollateralConfig memory) {
        return _collateral[token];
    }

    function getBook(uint32 bookId) external view override returns (Book memory) {
        if (bookId >= _books.length) revert UnknownBook();
        return _books[bookId];
    }

    function bookCount() external view override returns (uint32) {
        return uint32(_books.length);
    }

    function bookDuration(uint32 bookId) external view override returns (uint32) {
        if (bookId >= _books.length) revert UnknownBook();
        return _terms[_books[bookId].termId].duration;
    }

    function isBookActive(uint32 bookId) public view override returns (bool) {
        if (bookId >= _books.length) return false;
        Book storage b = _books[bookId];
        return b.enabled && _terms[b.termId].enabled && _collateral[b.collateral].enabled;
    }

    function _setParams(Params memory p) internal {
        if (p.minOrderSize == 0) revert InvalidParam();
        if (p.maxRateBps == 0 || p.maxRateBps > 100_000) revert InvalidParam();
        if (p.auctionFeeBpsPerYear > MAX_FEE_BPS_PER_YEAR) revert InvalidParam();
        if (p.noRevealPenaltyBps > MAX_NO_REVEAL_PENALTY_BPS) revert InvalidParam();
        if (p.maxOrdersPerSide == 0 || p.maxOrdersPerSide > HARD_MAX_ORDERS_PER_SIDE) revert InvalidParam();
        if (p.marginCallGracePeriod < MIN_GRACE || p.marginCallGracePeriod > MAX_GRACE) revert InvalidParam();
        if (p.maturityGracePeriod < MIN_GRACE || p.maturityGracePeriod > MAX_GRACE) revert InvalidParam();
        _params = p;
        emit ParamsUpdated(p);
    }
}

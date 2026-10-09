// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ProtocolAccess} from "../access/ProtocolAccess.sol";
import {IRepoNote} from "../interfaces/IRepoNote.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";

/// @title NoteMarket
/// @notice Fixed-price secondary market for repo notes so lenders can exit before maturity.
///         Sellers escrow notes and set a price per note unit (E18-scaled stablecoin per unit, e.g. 0.995e18).
///         Buyers fill any amount up to the listing, with a max price and a deadline. A small fee goes to the
///         FeeCollector.
contract NoteMarket is ProtocolAccess, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 100;

    struct Listing {
        address seller;
        uint256 seriesId;
        uint128 amount; // remaining note units
        uint128 priceE18; // stablecoin units per note unit, scaled by 1e18
        bool active;
    }

    IRepoNote public immutable note;
    IERC20 public immutable stable;
    address public feeCollector;
    IComplianceRegistry public compliance;
    uint16 public feeBps = 10;

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) internal _listings;

    event Listed(
        uint256 indexed listingId, address indexed seller, uint256 indexed seriesId, uint256 amount, uint256 priceE18
    );
    event Cancelled(uint256 indexed listingId);
    event PriceUpdated(uint256 indexed listingId, uint256 priceE18);
    event Bought(uint256 indexed listingId, address indexed buyer, uint256 amount, uint256 cost, uint256 fee);
    event FeeSet(uint16 bps);
    event FeeCollectorSet(address fc);
    event ComplianceSet(address compliance);

    error NotSeller();
    error NotActive();
    error ZeroAmount();
    error Expired();
    error PriceAboveMax();
    error NotAllowed();

    constructor(address admin, IRepoNote note_, IERC20 stable_, address feeCollector_) ProtocolAccess(admin) {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        note = note_;
        stable = stable_;
        feeCollector = feeCollector_;
    }

    function setFee(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_FEE_BPS) revert InvalidParam();
        feeBps = bps;
        emit FeeSet(bps);
    }

    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fc == address(0)) revert ZeroAddress();
        feeCollector = fc;
        emit FeeCollectorSet(fc);
    }

    function setCompliance(IComplianceRegistry c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = c;
        emit ComplianceSet(address(c));
    }

    function getListing(uint256 id) external view returns (Listing memory) {
        return _listings[id];
    }

    function quote(uint256 listingId, uint256 amount) public view returns (uint256 cost, uint256 fee) {
        cost = Math.mulDiv(amount, _listings[listingId].priceE18, 1e18, Math.Rounding.Ceil);
        fee = (cost * feeBps) / 10_000;
    }

    function list(uint256 seriesId, uint256 amount, uint256 priceE18)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        _checkCompliance(msg.sender);
        if (amount == 0 || priceE18 == 0 || amount > type(uint128).max || priceE18 > type(uint128).max) {
            revert ZeroAmount();
        }
        id = nextListingId++;
        _listings[id] = Listing({
            seller: msg.sender, seriesId: seriesId, amount: uint128(amount), priceE18: uint128(priceE18), active: true
        });
        emit Listed(id, msg.sender, seriesId, amount, priceE18);
        note.safeTransferFrom(msg.sender, address(this), seriesId, amount, "");
    }

    function updatePrice(uint256 listingId, uint256 priceE18) external {
        Listing storage l = _listings[listingId];
        if (l.seller != msg.sender) revert NotSeller();
        if (!l.active) revert NotActive();
        if (priceE18 == 0 || priceE18 > type(uint128).max) revert ZeroAmount();
        l.priceE18 = uint128(priceE18);
        emit PriceUpdated(listingId, priceE18);
    }

    /// @notice Cancelling is never paused or gated so sellers can always recover their notes.
    function cancel(uint256 listingId) external nonReentrant {
        Listing storage l = _listings[listingId];
        if (l.seller != msg.sender) revert NotSeller();
        if (!l.active) revert NotActive();
        uint256 amount = l.amount;
        l.active = false;
        l.amount = 0;
        emit Cancelled(listingId);
        note.safeTransferFrom(address(this), msg.sender, l.seriesId, amount, "");
    }

    function buy(uint256 listingId, uint256 amount, uint256 maxPriceE18, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 cost)
    {
        if (block.timestamp > deadline) revert Expired();
        _checkCompliance(msg.sender);
        Listing storage l = _listings[listingId];
        if (!l.active) revert NotActive();
        if (l.priceE18 > maxPriceE18) revert PriceAboveMax();
        if (amount == 0 || amount > l.amount) revert ZeroAmount();
        uint256 fee;
        (cost, fee) = quote(listingId, amount);
        l.amount -= uint128(amount);
        if (l.amount == 0) l.active = false;
        address seller = l.seller;
        uint256 seriesId = l.seriesId;
        emit Bought(listingId, msg.sender, amount, cost, fee);

        stable.safeTransferFrom(msg.sender, seller, cost - fee);
        if (fee > 0) stable.safeTransferFrom(msg.sender, feeCollector, fee);
        note.safeTransferFrom(address(this), msg.sender, seriesId, amount, "");
    }

    function _checkCompliance(address account) internal view {
        if (address(compliance) != address(0) && !compliance.isAllowed(account)) revert NotAllowed();
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, ERC1155Holder) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

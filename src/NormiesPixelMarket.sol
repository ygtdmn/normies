// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesPixelMarket } from "./interfaces/INormiesPixelMarket.sol";
import { INormiesCanvasStorageV2 } from "./interfaces/INormiesCanvasStorageV2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";
import { ReentrancyGuardTransient } from "solady/utils/ReentrancyGuardTransient.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/**
 * @title NormiesPixelMarket
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Sell-side order book for pixels, priced in ETH per pixel. Listing escrows the pixels in this contract's
 *         wallet balance; a fill moves them to the buyer and pays the seller minus the fee. Listings are either
 *         partial-fill or all-or-nothing and can be cancelled at any time. Once a listing has expired anyone can
 *         return its unsold pixels to the seller (reclaimExpired), so escrow never depends on the seller alone.
 */
contract NormiesPixelMarket is INormiesPixelMarket, Ownable, Lifebuoy, ReentrancyGuardTransient {
    error Paused();
    error MigrationNotFinalized();
    error ZeroAmount();
    error ZeroPrice();
    error PriceBelowMinimum(uint96 pricePerPixel, uint96 minimum);
    error ExpiryInPast();
    error ListingNotActive(uint256 listingId);
    error ListingExpired(uint256 listingId);
    error InvalidAmount(uint256 requested, uint256 remaining);
    error FullFillRequired(uint256 remaining);
    error IncorrectPayment(uint256 expected, uint256 sent);
    error NotSeller();
    error ListingNotExpired(uint256 listingId);
    error LengthMismatch();
    error FeeTooHigh();
    error InvalidBps();
    error FeeRecipientsNotSet();

    event ListingCreated(
        uint256 indexed listingId,
        address indexed seller,
        uint96 pricePerPixel,
        uint32 amount,
        bool partialFill,
        uint64 expiry
    );
    event ListingFilled(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        uint32 amount,
        uint32 remaining,
        uint256 grossWei,
        uint256 feeWei
    );
    /// @dev Emitted by cancel and by reclaimExpired, so a closed listing always looks the same to an indexer.
    event ListingCancelled(uint256 indexed listingId, address indexed seller, uint32 refunded);
    /// @notice An expired listing was returned to its seller by `reclaimedBy` (anyone). Follows ListingCancelled.
    event ListingReclaimed(uint256 indexed listingId, address indexed reclaimedBy);
    /// @notice Fees of one buy or batchBuy, paid to the recipients in that same transaction.
    event FeesPaid(uint256 treasuryWei, uint256 revenueShareWei);
    event FeeConfigSet(uint16 feeBps, uint16 revenueShareBps);
    event FeeRecipientsSet(address indexed treasury, address indexed revenueShare);
    event PausedSet(bool paused);
    event MinPricePerPixelSet(uint96 minPricePerPixel);

    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 internal constant BPS = 10_000;

    /// @notice Where pixel balances live (NormiesCanvasStorageV2); the market holds ROLE_MARKET there.
    INormiesCanvasStorageV2 public immutable pixels;

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) internal _listings;

    /// @notice Fee taken out of seller proceeds, in basis points of the gross.
    uint16 public feeBps = 1000;
    /**
     * @notice The lowest price a listing may carry, in wei per pixel. Starts at 0.0018 ETH, about five dollars at
     *         deployment; the owner replaces it with setMinPricePerPixel as the ETH price moves.
     *
     *         Why: without a floor a listing at 1 wei is a free transfer. The fee is a percentage of the price, so
     *         it rounds to nothing, and two wallets (or one wallet and a contract) could hand pixels to each other
     *         through the market without paying the holders anything. With a real floor every fill pays a real fee.
     */
    uint96 public minPricePerPixel = 0.0018 ether;
    /// @notice Share of the fee that goes to the revenue-share recipient, in basis points of the fee.
    uint16 public revenueShareBps = 5000;
    address public treasuryRecipient;
    address public revenueShareRecipient;

    /// @notice Starts paused; unpausing needs storage V2's migration to be finalized.
    bool public paused = true;

    constructor(INormiesCanvasStorageV2 _pixels) Ownable() Lifebuoy() {
        pixels = _pixels;
    }

    modifier whenNotPaused() {
        require(!paused, Paused());
        _;
    }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    // ──────────────────────────────────────────────
    //  Trading
    // ──────────────────────────────────────────────

    /// @notice Escrow `amount` pixels from your wallet balance and list them at `pricePerPixel` wei each.
    function list(
        uint32 amount,
        uint96 pricePerPixel,
        bool partialFill,
        uint64 expiry
    ) external whenNotPaused nonReentrant returns (uint256 listingId) {
        return _list(msg.sender, amount, pricePerPixel, partialFill, expiry);
    }

    /// @notice List `seller`'s pixels on their behalf. Needs an allowance from `seller` to the caller
    ///         (NormiesCanvasStorageV2.approve); an allowance is custody, since the caller may list at any price and
    ///         fill the listing itself. The listing belongs to `seller`: proceeds and cancellations go there.
    function listFrom(
        address seller,
        uint32 amount,
        uint96 pricePerPixel,
        bool partialFill,
        uint64 expiry
    ) external whenNotPaused nonReentrant returns (uint256 listingId) {
        pixels.useAllowance(seller, msg.sender, amount);
        return _list(seller, amount, pricePerPixel, partialFill, expiry);
    }

    function _list(
        address seller,
        uint32 amount,
        uint96 pricePerPixel,
        bool partialFill,
        uint64 expiry
    ) internal returns (uint256 listingId) {
        require(amount > 0, ZeroAmount());
        require(pricePerPixel > 0, ZeroPrice());
        require(pricePerPixel >= minPricePerPixel, PriceBelowMinimum(pricePerPixel, minPricePerPixel));
        require(expiry == 0 || expiry > block.timestamp, ExpiryInPast());
        pixels.moveBalance(seller, address(this), amount);
        listingId = nextListingId++;
        _listings[listingId] = Listing({
            seller: seller,
            expiry: expiry,
            partialFill: partialFill,
            status: Status.Active,
            pricePerPixel: pricePerPixel,
            amount: amount,
            remaining: amount
        });
        emit ListingCreated(listingId, seller, pricePerPixel, amount, partialFill, expiry);
    }

    /// @notice Buy `amount` pixels from a listing. Send exactly amount * pricePerPixel wei. The seller and the fee
    ///         recipients are paid in this transaction.
    function buy(uint256 listingId, uint32 amount) external payable whenNotPaused nonReentrant {
        uint256 gross = _quote(listingId, amount);
        require(msg.value == gross, IncorrectPayment(gross, msg.value));
        (uint256 toTreasury, uint256 toRevenueShare) = _fill(listingId, amount, gross);
        _payFees(toTreasury, toRevenueShare);
    }

    /// @notice Fill several listings at once (a floor sweep). Send exactly the sum of every fill's gross; every fill
    ///         has to succeed or the whole batch reverts. Fees are paid once for the batch.
    function batchBuy(
        uint256[] calldata listingIds,
        uint32[] calldata amounts
    ) external payable whenNotPaused nonReentrant {
        require(listingIds.length == amounts.length && listingIds.length > 0, LengthMismatch());
        uint256 total;
        for (uint256 i; i < listingIds.length; i++) {
            total += _quote(listingIds[i], amounts[i]);
        }
        require(msg.value == total, IncorrectPayment(total, msg.value));
        uint256 toTreasury;
        uint256 toRevenueShare;
        for (uint256 i; i < listingIds.length; i++) {
            (uint256 t, uint256 r) =
                _fill(listingIds[i], amounts[i], uint256(amounts[i]) * _listings[listingIds[i]].pricePerPixel);
            toTreasury += t;
            toRevenueShare += r;
        }
        _payFees(toTreasury, toRevenueShare);
    }

    /// @dev Validates a fill and prices it, without touching state. The same listing may appear twice in a batch;
    ///      the second quote is checked again by _fill against the remaining amount.
    function _quote(uint256 listingId, uint32 amount) internal view returns (uint256 gross) {
        Listing storage listing = _listings[listingId];
        require(listing.status == Status.Active, ListingNotActive(listingId));
        require(listing.expiry == 0 || block.timestamp < listing.expiry, ListingExpired(listingId));
        uint32 remaining = listing.remaining;
        require(amount > 0 && amount <= remaining, InvalidAmount(amount, remaining));
        require(listing.partialFill || amount == remaining, FullFillRequired(remaining));
        gross = uint256(amount) * listing.pricePerPixel;
    }

    function _fill(
        uint256 listingId,
        uint32 amount,
        uint256 gross
    ) internal returns (uint256 toTreasury, uint256 toRevenueShare) {
        Listing storage listing = _listings[listingId];
        uint32 remaining = listing.remaining;
        require(listing.status == Status.Active && amount <= remaining, InvalidAmount(amount, remaining));
        remaining -= amount;
        listing.remaining = remaining;
        if (remaining == 0) listing.status = Status.Filled;

        uint256 fee = (gross * feeBps) / BPS;
        toRevenueShare = (fee * revenueShareBps) / BPS;
        toTreasury = fee - toRevenueShare;

        address seller = listing.seller;
        pixels.moveBalance(address(this), msg.sender, amount);
        SafeTransferLib.forceSafeTransferETH(seller, gross - fee, SafeTransferLib.GAS_STIPEND_NO_GRIEF);
        emit ListingFilled(listingId, msg.sender, seller, amount, remaining, gross, fee);
    }

    /// @dev Nothing accrues in this contract: fees leave with the fill. Both recipients must be set.
    function _payFees(uint256 toTreasury, uint256 toRevenueShare) internal {
        if (toTreasury == 0 && toRevenueShare == 0) return;
        require(treasuryRecipient != address(0) && revenueShareRecipient != address(0), FeeRecipientsNotSet());
        if (toTreasury > 0) {
            SafeTransferLib.forceSafeTransferETH(treasuryRecipient, toTreasury, SafeTransferLib.GAS_STIPEND_NO_GRIEF);
        }
        if (toRevenueShare > 0) {
            SafeTransferLib.forceSafeTransferETH(
                revenueShareRecipient, toRevenueShare, SafeTransferLib.GAS_STIPEND_NO_GRIEF
            );
        }
        emit FeesPaid(toTreasury, toRevenueShare);
    }

    /// @notice Cancel your listing and take the unsold pixels back. Works while paused and after expiry.
    function cancel(uint256 listingId) external nonReentrant {
        Listing storage listing = _listings[listingId];
        require(listing.status == Status.Active, ListingNotActive(listingId));
        require(listing.seller == msg.sender, NotSeller());

        uint32 refund = listing.remaining;
        listing.remaining = 0;
        listing.status = Status.Cancelled;
        if (refund > 0) pixels.moveBalance(address(this), msg.sender, refund);

        emit ListingCancelled(listingId, msg.sender, refund);
    }

    /**
     * @notice Return an expired listing's unsold pixels to its seller. Anyone may call it, so pixels never stay in
     *         escrow because a seller lost their key or listed from a contract that cannot cancel. The pixels only
     *         ever go to the seller, and arrive without a cooldown (they were past it when listed). Works while
     *         paused. A listing without an expiry never expires; only its seller can close it.
     */
    function reclaimExpired(uint256 listingId) external nonReentrant {
        Listing storage listing = _listings[listingId];
        require(listing.status == Status.Active, ListingNotActive(listingId));
        uint64 expiry = listing.expiry;
        require(expiry != 0 && block.timestamp >= expiry, ListingNotExpired(listingId));

        address seller = listing.seller;
        uint32 refund = listing.remaining;
        listing.remaining = 0;
        listing.status = Status.Cancelled;
        if (refund > 0) pixels.releaseEscrow(seller, refund);

        emit ListingCancelled(listingId, seller, refund);
        emit ListingReclaimed(listingId, msg.sender);
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    /// @notice Replaces the listing floor (see minPricePerPixel). Open listings below the new floor stay as they are.
    function setMinPricePerPixel(uint96 _minPricePerPixel) external onlyOwner {
        minPricePerPixel = _minPricePerPixel;
        emit MinPricePerPixelSet(_minPricePerPixel);
    }

    function setFeeConfig(uint16 _feeBps, uint16 _revenueShareBps) external onlyOwner {
        require(_feeBps <= MAX_FEE_BPS, FeeTooHigh());
        require(_revenueShareBps <= BPS, InvalidBps());
        feeBps = _feeBps;
        revenueShareBps = _revenueShareBps;
        emit FeeConfigSet(_feeBps, _revenueShareBps);
    }

    function setFeeRecipients(address _treasury, address _revenueShare) external onlyOwner {
        treasuryRecipient = _treasury;
        revenueShareRecipient = _revenueShare;
        emit FeeRecipientsSet(_treasury, _revenueShare);
    }

    function setPaused(bool _paused) external onlyOwner {
        if (!_paused) require(pixels.migrationFinalized(), MigrationNotFinalized());
        paused = _paused;
        emit PausedSet(_paused);
    }
}

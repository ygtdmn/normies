// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesCanvasStorageV2 } from "./INormiesCanvasStorageV2.sol";

interface INormiesPixelMarket {
    enum Status {
        None,
        Active,
        Filled,
        Cancelled
    }

    struct Listing {
        address seller;
        uint64 expiry;
        bool partialFill;
        Status status;
        uint96 pricePerPixel;
        uint32 amount;
        uint32 remaining;
    }

    function list(
        uint32 amount,
        uint96 pricePerPixel,
        bool partialFill,
        uint64 expiry
    ) external returns (uint256 listingId);
    function listFrom(
        address seller,
        uint32 amount,
        uint96 pricePerPixel,
        bool partialFill,
        uint64 expiry
    ) external returns (uint256 listingId);
    function buy(uint256 listingId, uint32 amount) external payable;
    function batchBuy(uint256[] calldata listingIds, uint32[] calldata amounts) external payable;
    function cancel(uint256 listingId) external;
    function reclaimExpired(uint256 listingId) external;
    function getListing(uint256 listingId) external view returns (Listing memory);

    // State
    function MAX_FEE_BPS() external view returns (uint256);
    function pixels() external view returns (INormiesCanvasStorageV2);
    function nextListingId() external view returns (uint256);
    function feeBps() external view returns (uint16);
    function revenueShareBps() external view returns (uint16);
    function minPricePerPixel() external view returns (uint96);
    function treasuryRecipient() external view returns (address);
    function revenueShareRecipient() external view returns (address);
    function paused() external view returns (bool);

    // Admin: config (floor, fees), owner (recipients), guardian (pause)
    function setMinPricePerPixel(uint96 _minPricePerPixel) external;
    function setFeeConfig(uint16 _feeBps, uint16 _revenueShareBps) external;
    function setFeeRecipients(address _treasury, address _revenueShare) external;
    function setPaused(bool _paused) external;
}

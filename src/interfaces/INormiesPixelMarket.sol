// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

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
}

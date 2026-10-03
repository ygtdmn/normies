// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { PixelMarketBase } from "../PixelMarketBase.t.sol";
import { NormiesPixelMarket } from "../../src/NormiesPixelMarket.sol";
import { NormiesCanvasStorageV2 } from "../../src/NormiesCanvasStorageV2.sol";
import { INormiesPixelMarket } from "../../src/interfaces/INormiesPixelMarket.sol";

/// @notice Audit-only handler exercises actual public market paths, without mover privileges.
contract MarketReviewHandler is Test {
    NormiesPixelMarket public immutable market;
    NormiesCanvasStorageV2 public immutable pixels;
    address[3] public actors = [address(0xA001), address(0xA002), address(0xA003)];
    uint256[] public listings;
    uint256 public reclaims;

    constructor(NormiesPixelMarket market_, NormiesCanvasStorageV2 pixels_) {
        market = market_;
        pixels = pixels_;
    }

    function list(uint256 actor, uint32 rawAmount, uint96 rawPrice, bool partialFill, bool delegated) external {
        address seller = actors[actor % 3];
        uint256 available = pixels.availableBalance(seller);
        if (available == 0) return;
        uint32 amount = uint32(bound(rawAmount, 1, available > 10_000 ? 10_000 : available));
        uint96 price = uint96(bound(rawPrice, 1 gwei, 10 gwei));
        uint256 id;
        if (delegated) {
            address spender = actors[(actor % 3 + 1) % 3];
            vm.prank(seller);
            pixels.approve(spender, amount);
            vm.prank(spender);
            id = market.listFrom(seller, amount, price, partialFill, 0);
            assertEq(pixels.allowance(seller, spender), 0);
        } else {
            vm.prank(seller);
            id = market.list(amount, price, partialFill, 0);
        }
        listings.push(id);
    }

    /// @dev Listings that expire within five minutes, so the fuzzer sees buys, cancels and reclaims race expiry.
    function listExpiring(uint256 actor, uint32 rawAmount, uint96 rawPrice, bool partialFill, uint32 rawTtl) external {
        address seller = actors[actor % 3];
        uint256 available = pixels.availableBalance(seller);
        if (available == 0) return;
        uint32 amount = uint32(bound(rawAmount, 1, available > 10_000 ? 10_000 : available));
        uint96 price = uint96(bound(rawPrice, 1 gwei, 10 gwei));
        uint64 expiry = uint64(block.timestamp + bound(rawTtl, 1, 300));
        vm.prank(seller);
        listings.push(market.list(amount, price, partialFill, expiry));
    }

    function buy(uint256 listing, uint256 actor, uint32 rawAmount) external {
        if (listings.length == 0) return;
        uint256 id = listings[listing % listings.length];
        INormiesPixelMarket.Listing memory item = market.getListing(id);
        if (item.status != INormiesPixelMarket.Status.Active) return;
        if (item.expiry != 0 && block.timestamp >= item.expiry) return;
        uint32 amount = item.partialFill ? uint32(bound(rawAmount, 1, item.remaining)) : item.remaining;
        vm.prank(actors[actor % 3]);
        market.buy{ value: uint256(amount) * item.pricePerPixel }(id, amount);
    }

    function cancel(uint256 listing) external {
        if (listings.length == 0) return;
        uint256 id = listings[listing % listings.length];
        INormiesPixelMarket.Listing memory item = market.getListing(id);
        if (item.status != INormiesPixelMarket.Status.Active) return;
        vm.prank(item.seller);
        market.cancel(id);
    }

    /// @dev Any actor (seller or not) returns an expired listing; the pixels must land with the seller only.
    function reclaim(uint256 listing, uint256 actor) external {
        if (listings.length == 0) return;
        uint256 id = listings[listing % listings.length];
        INormiesPixelMarket.Listing memory item = market.getListing(id);
        if (item.status != INormiesPixelMarket.Status.Active) return;
        if (item.expiry == 0 || block.timestamp < item.expiry) return;
        uint256 before = pixels.balanceOf(item.seller);
        vm.prank(actors[actor % 3]);
        market.reclaimExpired(id);
        assertEq(pixels.balanceOf(item.seller), before + item.remaining);
        reclaims++;
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 120));
    }
}

contract MarketReviewEscrowInvariantTest is PixelMarketBase {
    MarketReviewHandler handler;
    uint256 constant INITIAL_PIXELS = 1_000_000;
    uint256 constant INITIAL_ETH = 1_000_000 ether;

    function setUp() public override {
        super.setUp();
        handler = new MarketReviewHandler(market, storageV2);
        for (uint256 i; i < 3; i++) {
            address actor = handler.actors(i);
            storageV2.mintTo(actor, INITIAL_PIXELS);
            vm.deal(actor, INITIAL_ETH);
        }
        handler.list(0, 100, 1 gwei, true, true);
        handler.buy(0, 1, 40);
        handler.cancel(0);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 128
    function invariant_publicMarketConservesEscrowPixelsAndEth() public view {
        uint256 open;
        for (uint256 id = 1; id < market.nextListingId(); id++) {
            INormiesPixelMarket.Listing memory item = market.getListing(id);
            if (item.status == INormiesPixelMarket.Status.Active) open += item.remaining;
            else assertEq(item.remaining, 0);
            assertLe(item.remaining, item.amount);
        }
        assertEq(storageV2.balanceOf(address(market)), open);
        uint256 walletPixels;
        uint256 cash = feeTreasury.balance + revShare.balance;
        for (uint256 i; i < 3; i++) {
            address actor = handler.actors(i);
            uint256 balance = storageV2.balanceOf(actor);
            walletPixels += balance;
            cash += actor.balance;
            assertLe(storageV2.availableBalance(actor), balance);
        }
        assertEq(walletPixels + open, 3 * INITIAL_PIXELS);
        assertEq(storageV2.totalWallet(), 3 * INITIAL_PIXELS);
        assertEq(storageV2.totalAttached(), 0);
        assertEq(address(market).balance, 0);
        assertEq(cash, 3 * INITIAL_ETH);
    }
}

contract MarketReviewBatchTest is PixelMarketBase {
    function testFuzzDuplicatePartialBatchConservesEscrow(uint32 rawA, uint32 rawB) public {
        uint32 a = uint32(bound(rawA, 1, 499));
        uint32 b = uint32(bound(rawB, 1, 499));
        storageV2.mintTo(user, 1000);
        vm.prank(user);
        uint256 id = market.list(1000, 1 gwei, true, 0);
        uint256[] memory ids = new uint256[](2);
        uint32[] memory amounts = new uint32[](2);
        ids[0] = id;
        ids[1] = id;
        amounts[0] = a;
        amounts[1] = b;
        vm.deal(buyer, uint256(a + b) * 1 gwei);
        vm.prank(buyer);
        market.batchBuy{ value: uint256(a + b) * 1 gwei }(ids, amounts);
        assertEq(storageV2.balanceOf(buyer), a + b);
        assertEq(storageV2.balanceOf(address(market)), 1000 - a - b);
        assertEq(market.getListing(id).remaining, 1000 - a - b);
        assertEq(user.balance + feeTreasury.balance + revShare.balance, uint256(a + b) * 1 gwei);
    }

    function testDuplicateOverfillRevertsEntireBatchAndAllPayments() public {
        storageV2.mintTo(user, 100);
        vm.prank(user);
        uint256 id = market.list(100, 1 gwei, true, 0);
        uint256[] memory ids = new uint256[](2);
        uint32[] memory amounts = new uint32[](2);
        ids[0] = id;
        ids[1] = id;
        amounts[0] = 60;
        amounts[1] = 60;
        vm.deal(buyer, 120 gwei);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.InvalidAmount.selector, 60, 40));
        market.batchBuy{ value: 120 gwei }(ids, amounts);
        assertEq(storageV2.balanceOf(address(market)), 100);
        assertEq(market.getListing(id).remaining, 100);
        assertEq(storageV2.balanceOf(buyer), 0);
        assertEq(buyer.balance, 120 gwei);
        assertEq(user.balance + feeTreasury.balance + revShare.balance, 0);
    }
}


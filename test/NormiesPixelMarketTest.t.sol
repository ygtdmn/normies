// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "./PixelMarketBase.t.sol";
import { NormiesPixelMarket } from "../src/NormiesPixelMarket.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { INormiesPixelMarket } from "../src/interfaces/INormiesPixelMarket.sol";
import { INormiesCanvasStorageV2 } from "../src/interfaces/INormiesCanvasStorageV2.sol";

/// @notice Seller whose receive() always reverts.
contract RevertingSeller {
    receive() external payable {
        revert("no");
    }
}

/// @notice Seller that tries to re-enter the market while being paid.
contract ReentrantSeller {
    NormiesPixelMarket public market;
    uint256 public listingId;
    bool public attempted;

    constructor(NormiesPixelMarket _market) {
        market = _market;
    }

    function setListing(uint256 id) external {
        listingId = id;
    }

    function listOn(uint32 amount, uint96 price) external returns (uint256) {
        return market.list(amount, price, true, 0);
    }

    receive() external payable {
        attempted = true;
        market.cancel(listingId);
    }
}

contract NormiesPixelMarketTest is PixelMarketBase {
    address seller = address(0x5E11);

    function setUp() public override {
        super.setUp();
        // The test contract acts as a mover so wallets can be funded without burning fodder.
        storageV2.setMoverRoles(address(this), storageV2.ROLE_CANVAS());
        vm.deal(buyer, 100 ether);
    }

    function _fund(address who, uint256 amount) internal {
        storageV2.mintTo(who, amount);
    }

    function _list(
        address who,
        uint32 amount,
        uint96 price,
        bool partialFill,
        uint64 expiry
    ) internal returns (uint256) {
        _fund(who, amount);
        vm.prank(who);
        return market.list(amount, price, partialFill, expiry);
    }

    // ──────────────────────────────────────────────
    //  Listing
    // ──────────────────────────────────────────────

    function testListEscrowsPixels() public {
        _fund(seller, 100);
        vm.expectEmit(true, true, false, true);
        emit NormiesPixelMarket.ListingCreated(1, seller, 1 gwei, 100, true, 0);
        vm.prank(seller);
        uint256 id = market.list(100, 1 gwei, true, 0);
        assertEq(id, 1);
        assertEq(storageV2.balanceOf(seller), 0);
        assertEq(storageV2.balanceOf(address(market)), 100);
        INormiesPixelMarket.Listing memory l = market.getListing(id);
        assertEq(l.seller, seller);
        assertEq(l.amount, 100);
        assertEq(l.remaining, 100);
        assertEq(l.pricePerPixel, 1 gwei);
        assertTrue(l.partialFill);
        assertEq(uint8(l.status), uint8(INormiesPixelMarket.Status.Active));
    }

    function testListValidation() public {
        _fund(seller, 10);
        vm.startPrank(seller);
        vm.expectRevert(NormiesPixelMarket.ZeroAmount.selector);
        market.list(0, 1, true, 0);
        vm.expectRevert(NormiesPixelMarket.ZeroPrice.selector);
        market.list(1, 0, true, 0);
        vm.expectRevert(NormiesPixelMarket.ExpiryInPast.selector);
        market.list(1, 1, true, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientBalance.selector, seller, 10, 11));
        market.list(11, 1, true, 0);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Buying
    // ──────────────────────────────────────────────

    function testPartialFillPaysSellerAndFeesAtOnce() public {
        uint256 id = _list(seller, 100, 0.01 ether, true, 0);
        uint256 gross = 40 * 0.01 ether;
        vm.expectEmit(true, true, true, true);
        emit NormiesPixelMarket.ListingFilled(id, buyer, seller, 40, 60, gross, gross / 10);
        vm.prank(buyer);
        market.buy{ value: gross }(id, 40);

        assertEq(seller.balance, gross - gross / 10);
        assertEq(feeTreasury.balance, gross / 20);
        assertEq(revShare.balance, gross / 20);
        assertEq(address(market).balance, 0);
        assertEq(storageV2.balanceOf(buyer), 40);
        assertEq(storageV2.balanceOf(address(market)), 60);
        INormiesPixelMarket.Listing memory l = market.getListing(id);
        assertEq(l.remaining, 60);
        assertEq(uint8(l.status), uint8(INormiesPixelMarket.Status.Active));

        vm.prank(buyer);
        market.buy{ value: 60 * 0.01 ether }(id, 60);
        l = market.getListing(id);
        assertEq(l.remaining, 0);
        assertEq(uint8(l.status), uint8(INormiesPixelMarket.Status.Filled));
        assertEq(storageV2.balanceOf(address(market)), 0);
    }

    function testFullFillOnly() public {
        uint256 id = _list(seller, 100, 1 gwei, false, 0);
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.FullFillRequired.selector, 100));
        market.buy{ value: 40 gwei }(id, 40);
        market.buy{ value: 100 gwei }(id, 100);
        vm.stopPrank();
        assertEq(storageV2.balanceOf(buyer), 100);
    }

    function testBuyValidation() public {
        uint256 id = _list(seller, 10, 1 gwei, true, 0);
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.IncorrectPayment.selector, 5 gwei, 4 gwei));
        market.buy{ value: 4 gwei }(id, 5);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.InvalidAmount.selector, 11, 10));
        market.buy{ value: 11 gwei }(id, 11);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.InvalidAmount.selector, 0, 10));
        market.buy{ value: 0 }(id, 0);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotActive.selector, 7));
        market.buy{ value: 1 gwei }(7, 1);
        vm.stopPrank();
    }

    function testExpiryBlocksBuyNotCancel() public {
        uint64 expiry = uint64(block.timestamp + 100);
        uint256 id = _list(seller, 10, 1 gwei, true, expiry);
        vm.warp(expiry);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingExpired.selector, id));
        market.buy{ value: 1 gwei }(id, 1);
        vm.prank(seller);
        market.cancel(id);
        assertEq(storageV2.balanceOf(seller), 10);
    }

    function testFuzzFeeAccounting(uint96 price, uint32 amount, uint16 fee, uint16 rev) public {
        price = uint96(bound(price, 1, 1 ether));
        amount = uint32(bound(amount, 1, 5000));
        fee = uint16(bound(fee, 0, 1000));
        rev = uint16(bound(rev, 0, 10_000));
        market.setFeeConfig(fee, rev);

        uint256 id = _list(seller, amount, price, true, 0);
        uint256 gross = uint256(amount) * price;
        vm.deal(buyer, gross);
        vm.prank(buyer);
        market.buy{ value: gross }(id, amount);

        assertEq(buyer.balance, 0);
        assertEq(seller.balance + feeTreasury.balance + revShare.balance, gross);
        assertEq(address(market).balance, 0);
        assertEq(storageV2.balanceOf(buyer), amount);
    }

    // ──────────────────────────────────────────────
    //  Cancel
    // ──────────────────────────────────────────────

    function testCancelRefundsRemaining() public {
        uint256 id = _list(seller, 100, 1 gwei, true, 0);
        vm.prank(buyer);
        market.buy{ value: 30 gwei }(id, 30);
        vm.prank(unauthorized);
        vm.expectRevert(NormiesPixelMarket.NotSeller.selector);
        market.cancel(id);
        vm.expectEmit(true, true, false, true);
        emit NormiesPixelMarket.ListingCancelled(id, seller, 70);
        vm.prank(seller);
        market.cancel(id);
        assertEq(storageV2.balanceOf(seller), 70);
        assertEq(storageV2.balanceOf(address(market)), 0);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotActive.selector, id));
        market.cancel(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotActive.selector, id));
        market.buy{ value: 1 gwei }(id, 1);
    }

    function testCancelWorksWhilePaused() public {
        uint256 id = _list(seller, 10, 1 gwei, true, 0);
        market.setPaused(true);
        vm.prank(buyer);
        vm.expectRevert(NormiesPixelMarket.Paused.selector);
        market.buy{ value: 1 gwei }(id, 1);
        _fund(seller, 1);
        vm.prank(seller);
        vm.expectRevert(NormiesPixelMarket.Paused.selector);
        market.list(1, 1, true, 0);
        vm.prank(seller);
        market.cancel(id);
        assertEq(storageV2.balanceOf(seller), 11);
    }

    // ──────────────────────────────────────────────
    //  Fees
    // ──────────────────────────────────────────────

    function testFeeConfigLimits() public {
        vm.expectRevert(NormiesPixelMarket.FeeTooHigh.selector);
        market.setFeeConfig(1001, 5000);
        vm.expectRevert(NormiesPixelMarket.InvalidBps.selector);
        market.setFeeConfig(1000, 10_001);
        vm.prank(unauthorized);
        vm.expectRevert("Ownable: caller is not the owner");
        market.setFeeConfig(500, 5000);
        market.setFeeConfig(500, 2000);
        assertEq(market.feeBps(), 500);
        assertEq(market.revenueShareBps(), 2000);

        uint256 id = _list(seller, 100, 1 ether, true, 0);
        vm.prank(buyer);
        market.buy{ value: 100 ether }(id, 100);
        assertEq(revShare.balance, 1 ether); // 5% fee = 5 ETH, 20% of it
        assertEq(feeTreasury.balance, 4 ether);
        assertEq(seller.balance, 95 ether);
    }

    function testFeesLeaveWithTheFill() public {
        uint256 id = _list(seller, 100, 1 ether, true, 0);
        vm.expectEmit(false, false, false, true);
        emit NormiesPixelMarket.FeesPaid(5 ether, 5 ether);
        vm.prank(buyer);
        market.buy{ value: 100 ether }(id, 100);
        assertEq(feeTreasury.balance, 5 ether);
        assertEq(revShare.balance, 5 ether);
        assertEq(address(market).balance, 0);
    }

    function testBuyNeedsFeeRecipients() public {
        market.setFeeRecipients(address(0), address(0));
        uint256 id = _list(seller, 10, 1 ether, true, 0);
        vm.prank(buyer);
        vm.expectRevert(NormiesPixelMarket.FeeRecipientsNotSet.selector);
        market.buy{ value: 10 ether }(id, 10);
    }

    function testBatchBuySweepsSeveralListingsWithOneFeePayment() public {
        address other = address(0x5E12);
        _fund(other, 50);
        uint256 a = _list(seller, 100, 1 ether, true, 0);
        uint256 b = _list(other, 50, 2 ether, false, 0);
        uint256[] memory ids = new uint256[](2);
        uint32[] memory amounts = new uint32[](2);
        (ids[0], amounts[0]) = (a, 40);
        (ids[1], amounts[1]) = (b, 50);
        uint256 total = 40 ether + 100 ether;
        vm.deal(buyer, total);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.IncorrectPayment.selector, total, total - 1));
        market.batchBuy{ value: total - 1 }(ids, amounts);

        vm.expectEmit(false, false, false, true);
        emit NormiesPixelMarket.FeesPaid(7 ether, 7 ether); // 10% of 140
        vm.prank(buyer);
        market.batchBuy{ value: total }(ids, amounts);
        assertEq(storageV2.balanceOf(buyer), 90);
        assertEq(seller.balance, 36 ether);
        assertEq(other.balance, 90 ether);
        assertEq(market.getListing(a).remaining, 60);
        assertEq(uint8(market.getListing(b).status), uint8(INormiesPixelMarket.Status.Filled));
        assertEq(address(market).balance, 0);

        // One bad fill reverts the whole batch: b is filled now.
        vm.deal(buyer, total);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotActive.selector, b));
        market.batchBuy{ value: total }(ids, amounts);
        uint32[] memory wrong = new uint32[](1);
        vm.prank(buyer);
        vm.expectRevert(NormiesPixelMarket.LengthMismatch.selector);
        market.batchBuy(ids, wrong);
    }

    // ──────────────────────────────────────────────
    //  Hostile sellers
    // ──────────────────────────────────────────────

    function testRevertingSellerCannotBlockFill() public {
        RevertingSeller hostile = new RevertingSeller();
        uint256 id = _list(address(hostile), 10, 1 ether, true, 0);
        vm.prank(buyer);
        market.buy{ value: 10 ether }(id, 10);
        assertEq(address(hostile).balance, 9 ether);
        assertEq(storageV2.balanceOf(buyer), 10);
    }

    function testReentrantSellerIsBlockedAndStillPaid() public {
        ReentrantSeller hostile = new ReentrantSeller(market);
        _fund(address(hostile), 10);
        uint256 id = hostile.listOn(10, 1 ether);
        hostile.setListing(id);
        vm.prank(buyer);
        market.buy{ value: 4 ether }(id, 4);
        // The re-entrant cancel reverts inside receive(), so the stipend call fails (and its state write is
        // rolled back); the payment still lands through the forced transfer.
        assertFalse(hostile.attempted());
        assertEq(address(hostile).balance, 3.6 ether);
        INormiesPixelMarket.Listing memory l = market.getListing(id);
        assertEq(l.remaining, 6);
        assertEq(uint8(l.status), uint8(INormiesPixelMarket.Status.Active));
        assertEq(storageV2.balanceOf(address(market)), 6);
    }

    // ──────────────────────────────────────────────
    //  Escrow invariant over a sequence
    // ──────────────────────────────────────────────

    function testEscrowMatchesOpenListings() public {
        uint256 a = _list(seller, 100, 1 gwei, true, 0);
        uint256 b = _list(seller, 50, 2 gwei, false, 0);
        uint256 c = _list(buyer, 20, 3 gwei, true, 0);
        vm.prank(buyer);
        market.buy{ value: 25 gwei }(a, 25);
        vm.prank(buyer);
        market.buy{ value: 100 gwei }(b, 50);
        vm.prank(buyer);
        market.cancel(c);
        uint256 open = market.getListing(a).remaining + market.getListing(b).remaining + market.getListing(c).remaining;
        assertEq(open, 75);
        assertEq(storageV2.balanceOf(address(market)), open);
    }

    // ──────────────────────────────────────────────
    //  Price floor
    // ──────────────────────────────────────────────

    function testListingFloorStopsDustListings() public {
        NormiesPixelMarket fresh = new NormiesPixelMarket(INormiesCanvasStorageV2(address(storageV2)));
        assertEq(fresh.minPricePerPixel(), 0.0018 ether); // about five dollars at deployment
        storageV2.setMoverRoles(address(fresh), storageV2.ROLE_MARKET());
        fresh.setFeeRecipients(feeTreasury, revShare);
        fresh.setPaused(false);
        _fund(seller, 100);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.PriceBelowMinimum.selector, 1, 0.0018 ether));
        fresh.list(100, 1, true, 0);
        vm.prank(seller);
        fresh.list(50, 0.0018 ether, true, 0);

        vm.prank(unauthorized);
        vm.expectRevert("Ownable: caller is not the owner");
        fresh.setMinPricePerPixel(1);
        vm.expectEmit(false, false, false, true);
        emit NormiesPixelMarket.MinPricePerPixelSet(0.002 ether);
        fresh.setMinPricePerPixel(0.002 ether);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesPixelMarket.PriceBelowMinimum.selector, 0.0018 ether, 0.002 ether)
        );
        fresh.list(50, 0.0018 ether, true, 0);
    }

    // ──────────────────────────────────────────────
    //  Listing on someone's behalf
    // ──────────────────────────────────────────────

    function testListFromNeedsAllowanceAndBelongsToTheSeller() public {
        _fund(user, 100);
        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, seller, 0, 60)
        );
        market.listFrom(user, 60, 0.001 ether, true, 0);

        vm.prank(user);
        storageV2.approve(seller, 60);
        vm.prank(seller);
        uint256 id = market.listFrom(user, 60, 0.001 ether, true, 0);
        assertEq(market.getListing(id).seller, user);
        assertEq(storageV2.balanceOf(user), 40);
        assertEq(storageV2.allowance(user, seller), 0);

        // Proceeds go to the seller, and only the seller cancels.
        uint256 before = user.balance;
        vm.prank(buyer);
        market.buy{ value: 30 * 0.001 ether }(id, 30);
        assertEq(user.balance - before, 30 * 0.001 ether * 9 / 10);
        vm.prank(seller);
        vm.expectRevert(NormiesPixelMarket.NotSeller.selector);
        market.cancel(id);
        vm.prank(user);
        market.cancel(id);
        assertEq(storageV2.balanceOf(user), 70);
    }

    function testAllowancePauseStopsListFromButNotTheHolder() public {
        _fund(user, 100);
        vm.prank(user);
        storageV2.approve(seller, 60);
        storageV2.setAllowancesPaused(true);

        vm.prank(seller);
        vm.expectRevert(NormiesCanvasStorageV2.AllowancesPaused.selector);
        market.listFrom(user, 60, 0.001 ether, true, 0);

        // The holder's own listings, through either entry point, still work.
        vm.startPrank(user);
        uint256 id = market.list(40, 0.001 ether, true, 0);
        market.listFrom(user, 10, 0.001 ether, true, 0);
        vm.stopPrank();
        assertEq(market.getListing(id).seller, user);
        assertEq(storageV2.balanceOf(user), 50);

        storageV2.setAllowancesPaused(false);
        vm.prank(seller);
        market.listFrom(user, 50, 0.001 ether, true, 0);
        assertEq(storageV2.allowance(user, seller), 10);
        assertEq(storageV2.balanceOf(user), 0);
    }

    // ──────────────────────────────────────────────
    //  End to end with the canvas
    // ──────────────────────────────────────────────

    // ──────────────────────────────────────────────
    //  Reclaiming expired listings
    // ──────────────────────────────────────────────

    function testAnyoneReturnsAnExpiredListingToTheSeller() public {
        uint64 expiry = uint64(block.timestamp + 100);
        uint256 id = _list(seller, 100, 1 gwei, true, expiry);
        vm.prank(buyer);
        market.buy{ value: 30 gwei }(id, 30);

        // Not before expiry, by anyone, the seller included.
        vm.warp(expiry - 1);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotExpired.selector, id));
        market.reclaimExpired(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotExpired.selector, id));
        market.reclaimExpired(id);

        // From the expiry second on (the same second buying stops), a stranger returns the rest to the seller.
        vm.warp(expiry);
        vm.expectEmit(true, true, false, true);
        emit NormiesPixelMarket.ListingCancelled(id, seller, 70);
        vm.expectEmit(true, true, false, true);
        emit NormiesPixelMarket.ListingReclaimed(id, unauthorized);
        vm.prank(unauthorized);
        market.reclaimExpired(id);

        assertEq(storageV2.balanceOf(seller), 70);
        assertEq(storageV2.balanceOf(unauthorized), 0);
        assertEq(storageV2.balanceOf(address(market)), 0);
        INormiesPixelMarket.Listing memory l = market.getListing(id);
        assertEq(l.remaining, 0);
        assertEq(uint8(l.status), uint8(INormiesPixelMarket.Status.Cancelled));

        // Once closed it stays closed, for a reclaim and for the seller's cancel.
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotActive.selector, id));
        market.reclaimExpired(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotActive.selector, id));
        market.cancel(id);
    }

    function testListingsWithoutExpiryOrAlreadyClosedCannotBeReclaimed() public {
        uint256 open = _list(seller, 10, 1 gwei, true, 0);
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotExpired.selector, open));
        market.reclaimExpired(open);

        uint64 expiry = uint64(block.timestamp + 10);
        uint256 filled = _list(seller, 10, 1 gwei, false, expiry);
        vm.prank(buyer);
        market.buy{ value: 10 gwei }(filled, 10);
        vm.warp(expiry);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotActive.selector, filled));
        market.reclaimExpired(filled);

        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.ListingNotActive.selector, 999));
        market.reclaimExpired(999);
    }

    function testReclaimWorksWhilePausedAndForAContractSeller() public {
        // A seller contract with no way to call cancel: its pixels still come home.
        RevertingSeller stuck = new RevertingSeller();
        uint64 expiry = uint64(block.timestamp + 10);
        uint256 id = _list(address(stuck), 25, 1 gwei, true, expiry);
        market.setPaused(true);
        vm.warp(expiry);
        vm.prank(unauthorized);
        market.reclaimExpired(id);
        assertEq(storageV2.balanceOf(address(stuck)), 25);
        assertEq(storageV2.balanceOf(address(market)), 0);
    }

    function testReclaimDoesNotRestartTheSellersCooldown() public {
        // The seller has pixels still cooling from a purchase.
        address other = address(0x5E12);
        uint256 source = _list(other, 40, 1 gwei, true, 0);
        vm.deal(seller, 1 ether);
        vm.prank(seller);
        market.buy{ value: 40 gwei }(source, 40);
        uint64 unlock = storageV2.unlockAt(seller);
        uint256 locked = storageV2.lockedBalance(seller);
        assertEq(locked, 40);

        // An expired listing of theirs is returned by a stranger in the same window.
        uint64 expiry = uint64(block.timestamp + 10);
        uint256 id = _list(seller, 15, 1 gwei, true, expiry);
        vm.warp(expiry);
        assertLt(block.timestamp, unlock); // the purchase is still cooling
        vm.prank(unauthorized);
        market.reclaimExpired(id);

        // The returned pixels are spendable at once, and the purchase unlocks exactly when it would have.
        assertEq(storageV2.unlockAt(seller), unlock);
        assertEq(storageV2.lockedBalance(seller), locked);
        assertEq(storageV2.availableBalance(seller), 15);
        vm.prank(seller);
        market.list(15, 1 gwei, true, 0);
    }

    function testWithdrawListBuyDeposit() public {
        _mintRealTo(user, 1);
        _mintRealTo(buyer, 2);
        uint256 got = _giveTokenPixels(user, 1, 48);
        vm.startPrank(user);
        canvas.withdrawPixels(1, got, false);
        _cool();
        uint256 id = market.list(uint32(got), 0.001 ether, true, 0);
        vm.stopPrank();
        vm.startPrank(buyer);
        market.buy{ value: got * 0.001 ether }(id, uint32(got));
        _cool();
        canvas.depositPixels(2, got);
        vm.stopPrank();
        assertEq(storageV2.attachedOf(1), 0);
        assertEq(storageV2.attachedOf(2), got);
        assertEq(canvas.getLevel(2), got / 10 + 1);
    }
}

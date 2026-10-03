// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { PixelMarketBase } from "./PixelMarketBase.t.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { NormiesPixelMarket } from "../src/NormiesPixelMarket.sol";
import { NormiesCanvasV2 } from "../src/NormiesCanvasV2.sol";
import { INormiesCanvasStorageV2 } from "../src/interfaces/INormiesCanvasStorageV2.sol";

/// @notice Random mover driving the storageV2 for the supply invariant.
contract LedgerHandler is Test {
    NormiesCanvasStorageV2 public storageV2;
    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];
    uint256[3] public tokens = [uint256(1), 2, 3];
    uint256 public minted;
    uint256 public burned;

    constructor(NormiesCanvasStorageV2 _storageV2) {
        storageV2 = _storageV2;
    }

    function mint(uint256 a, uint256 amt) external {
        amt = bound(amt, 0, 1000);
        storageV2.mintTo(actors[a % 3], amt);
        minted += amt;
    }

    function burn(uint256 a, uint256 amt) external {
        address from = actors[a % 3];
        uint256 bal = storageV2.balanceOf(from);
        if (bal == 0) return;
        amt = bound(amt, 0, bal);
        storageV2.burnFrom(from, amt);
        burned += amt;
    }

    function move(uint256 a, uint256 b, uint256 amt) external {
        address from = actors[a % 3];
        uint256 bal = storageV2.balanceOf(from);
        if (bal == 0) return;
        storageV2.moveBalance(from, actors[b % 3], bound(amt, 0, bal));
    }

    function attach(uint256 a, uint256 t, uint256 amt) external {
        address from = actors[a % 3];
        uint256 bal = storageV2.balanceOf(from);
        if (bal == 0) return;
        storageV2.attach(from, tokens[t % 3], bound(amt, 0, bal), INormiesCanvasStorageV2.Reason.Deposit);
    }

    function detach(uint256 a, uint256 t, uint256 amt) external {
        uint256 tokenId = tokens[t % 3];
        uint256 att = storageV2.attachedOf(tokenId);
        if (att == 0) return;
        storageV2.detach(tokenId, actors[a % 3], bound(amt, 0, att), INormiesCanvasStorageV2.Reason.Withdraw);
    }

    function credit(uint256 t, uint256 amt) external {
        amt = bound(amt, 0, 1000);
        storageV2.creditAttached(tokens[t % 3], amt, INormiesCanvasStorageV2.Reason.BurnReward);
        minted += amt;
    }

    function moveAttached(uint256 a, uint256 b, uint256 amt) external {
        uint256 fromId = tokens[a % 3];
        uint256 toId = tokens[b % 3];
        uint256 att = storageV2.attachedOf(fromId);
        if (att == 0 || fromId == toId) return;
        storageV2.moveAttached(fromId, toId, bound(amt, 0, att), INormiesCanvasStorageV2.Reason.BurnTransfer);
    }
}

contract NormiesPixelAccountingTest is PixelMarketBase {
    LedgerHandler handler;

    function setUp() public override {
        cutoverInSetUp = false; // this suite exercises the cutover itself
        super.setUp();
        handler = new LedgerHandler(storageV2);
        storageV2.setMoverRoles(
            address(handler), storageV2.ROLE_CANVAS() | storageV2.ROLE_MARKET() | storageV2.ROLE_WRAPPER()
        );
        targetContract(address(handler));
    }

    // ──────────────────────────────────────────────
    //  Access
    // ──────────────────────────────────────────────

    function testOnlyMoverGuards() public {
        vm.startPrank(unauthorized);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        storageV2.mintTo(user, 1);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        storageV2.moveBalance(user, buyer, 1);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        storageV2.creditAttached(1, 1, INormiesCanvasStorageV2.Reason.Deposit);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        storageV2.detach(1, user, 1, INormiesCanvasStorageV2.Reason.Withdraw);
        vm.stopPrank();
    }

    function testSetMoverOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert("Ownable: caller is not the owner");
        storageV2.setMoverRoles(unauthorized, 1);
        vm.expectRevert(NormiesCanvasStorageV2.ZeroAddress.selector);
        storageV2.setMoverRoles(address(0), 1);
    }

    function testRolesGateEachFunction() public {
        address wrapper = address(0xAA01);
        address marketOnly = address(0xAA02);
        storageV2.setMoverRoles(wrapper, storageV2.ROLE_WRAPPER());
        storageV2.setMoverRoles(marketOnly, storageV2.ROLE_MARKET());
        vm.prank(address(handler));
        storageV2.mintTo(user, 10);

        // A wrapper can move balances but can never mint or attach.
        vm.startPrank(wrapper);
        storageV2.moveBalance(user, buyer, 1);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        storageV2.mintTo(user, 1);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        storageV2.attach(user, 1, 1, INormiesCanvasStorageV2.Reason.Deposit);
        vm.stopPrank();

        // The market can move balances but cannot create pixels.
        vm.startPrank(marketOnly);
        storageV2.moveBalance(user, marketOnly, 2);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        storageV2.mintTo(user, 1);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        storageV2.creditAttached(1, 1, INormiesCanvasStorageV2.Reason.BurnReward);
        vm.stopPrank();
    }

    function testMoveAttachedMovesTheBalance() public {
        vm.startPrank(address(handler));
        storageV2.creditAttached(1, 40, INormiesCanvasStorageV2.Reason.BurnReward);
        storageV2.moveAttached(1, 2, 25, INormiesCanvasStorageV2.Reason.BurnTransfer);
        vm.stopPrank();
        assertEq(storageV2.attachedOf(1), 15);
        assertEq(storageV2.attachedOf(2), 25);
        assertEq(storageV2.totalAttached(), 40);
    }

    // ──────────────────────────────────────────────
    //  Migration from the original canvas
    // ──────────────────────────────────────────────

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function testNothingIsReadFromLegacyBeforeMigration() public {
        _earnOnV1(user, 1, 48);
        assertEq(storageV2.attachedOf(1), 0);
        assertFalse(storageV2.migrated(1));
        assertEq(storageV2.totalAttached(), 0);
    }

    function testMigrateBatchCopiesLegacyOnce() public {
        uint256 got1 = _earnOnV1(user, 1, 48);
        uint256 got2 = _earnOnV1(user, 2, 48);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3; // no legacy balance

        vm.expectEmit(true, false, false, true);
        emit NormiesCanvasStorageV2.TokenMigrated(1, got1);
        vm.prank(unauthorized); // permissionless
        storageV2.migrateBatch(ids);

        assertTrue(storageV2.migrated(1) && storageV2.migrated(2) && storageV2.migrated(3));
        assertEq(storageV2.attachedOf(1), got1);
        assertEq(storageV2.attachedOf(2), got2);
        assertEq(storageV2.attachedOf(3), 0);
        assertEq(storageV2.totalAttached(), got1 + got2);

        // A second copy, or a later change on the original canvas, changes nothing.
        _earnOnV1(user, 1, 48);
        assertGt(canvasV1.actionPoints(1), got1);
        storageV2.migrateBatch(ids);
        assertEq(storageV2.attachedOf(1), got1);
        assertEq(storageV2.totalAttached(), got1 + got2);
    }

    function testMigrationAddsToAnEarlierCredit() public {
        uint256 got = _earnOnV1(user, 1, 48);
        vm.prank(address(handler));
        storageV2.creditAttached(1, 5, INormiesCanvasStorageV2.Reason.Deposit);
        assertFalse(storageV2.migrated(1));
        storageV2.migrateBatch(_ids(1));
        assertEq(storageV2.attachedOf(1), got + 5);
    }

    function testFinalizeClosesMigration() public {
        vm.prank(unauthorized);
        vm.expectRevert("Ownable: caller is not the owner");
        storageV2.finalizeMigration();

        uint256 got = _earnOnV1(user, 1, 48);
        storageV2.migrateBatch(_ids(1));
        vm.expectEmit(false, false, false, true);
        emit NormiesCanvasStorageV2.MigrationFinalized(got);
        storageV2.finalizeMigration();
        assertTrue(storageV2.migrationFinalized());

        vm.expectRevert(NormiesCanvasStorageV2.MigrationClosed.selector);
        storageV2.migrateBatch(_ids(2));
        vm.expectRevert(NormiesCanvasStorageV2.MigrationClosed.selector);
        storageV2.finalizeMigration();
    }

    // ──────────────────────────────────────────────
    //  Cutover guards
    // ──────────────────────────────────────────────

    function testMigrateBatchNeedsTheOriginalCanvasPaused() public {
        canvasV1.setPaused(false);
        vm.expectRevert(NormiesCanvasStorageV2.LegacyCanvasNotPaused.selector);
        storageV2.migrateBatch(_ids(1));
        canvasV1.setPaused(true);
        storageV2.migrateBatch(_ids(1));
    }

    function testNothingUnpausesBeforeBothCopiesAreFinal() public {
        assertTrue(canvas.paused());
        assertTrue(market.paused());
        vm.expectRevert(NormiesCanvasV2.MigrationNotFinalized.selector);
        canvas.setPaused(false);
        vm.expectRevert(NormiesPixelMarket.MigrationNotFinalized.selector);
        market.setPaused(false);

        storageV2.finalizeMigration();
        market.setPaused(false); // the market only needs the balances
        vm.expectRevert(NormiesCanvasV2.MigrationNotFinalized.selector);
        canvas.setPaused(false); // the canvas also needs the delegations
        _sealDelegations(new uint256[](0), new address[](0), new address[](0));
        canvas.setPaused(false);
        assertFalse(canvas.paused());
        canvas.setPaused(true); // pausing again is always allowed
    }

    // ──────────────────────────────────────────────
    //  Delegation seeding
    // ──────────────────────────────────────────────

    function _one(
        uint256 id,
        address a,
        address b
    ) internal pure returns (uint256[] memory ids, address[] memory ds, address[] memory sbs) {
        ids = new uint256[](1);
        ds = new address[](1);
        sbs = new address[](1);
        ids[0] = id;
        ds[0] = a;
        sbs[0] = b;
    }

    function testSeededDelegationsWorkLikeOnesSetHere() public {
        _mintRealTo(user, 1);
        _mintRealTo(buyer, 2);
        uint256[] memory ids = new uint256[](2);
        address[] memory ds = new address[](2);
        address[] memory sbs = new address[](2);
        (ids[0], ds[0], sbs[0]) = (1, delegate_, user); // live: set by the current owner
        (ids[1], ds[1], sbs[1]) = (2, delegate_, user); // stale: set by someone who no longer owns #2

        storageV2.finalizeMigration();
        vm.prank(unauthorized);
        vm.expectRevert("Ownable: caller is not the owner");
        storageV2.seedAndFinalizeDelegations(ids, ds, sbs, block.number, block.timestamp);

        vm.expectEmit(true, true, false, true);
        emit NormiesCanvasStorageV2.DelegateSet(1, delegate_, user);
        _sealDelegations(ids, ds, sbs);
        _cutover();
        uint256 got = _giveTokenPixels(user, 1, 48);
        (address d, address setBy) = canvas.effectiveDelegate(1);
        assertEq(d, delegate_);
        assertEq(setBy, user);

        vm.prank(delegate_);
        canvas.setTransformBitmap(1, _createBitmapWithPixels(got));
        assertTrue(storageV2.isTransformed(1));
        vm.prank(delegate_);
        vm.expectRevert(NormiesCanvasV2.NotTokenOwnerOrDelegate.selector);
        canvas.setTransformBitmap(2, _createBitmapWithPixels(1));

        // The token owner can still revoke or replace a seeded delegate.
        vm.prank(user);
        canvas.revokeDelegate(1);
        (d,) = canvas.effectiveDelegate(1);
        assertEq(d, address(0));
    }

    function testDelegationCopyIsOneShot() public {
        (uint256[] memory ids, address[] memory ds, address[] memory sbs) = _one(1, delegate_, user);
        storageV2.finalizeMigration();
        vm.expectRevert(NormiesCanvasStorageV2.LengthMismatch.selector);
        storageV2.seedAndFinalizeDelegations(ids, ds, new address[](0), block.number, block.timestamp);
        assertFalse(storageV2.delegationsSeeded());

        storageV2.seedAndFinalizeDelegations(ids, ds, sbs, block.number, block.timestamp);
        assertTrue(storageV2.delegationsSeeded());
        assertEq(storageV2.delegates(1), delegate_);

        // Sealed for good: neither a second copy nor an empty one goes through.
        (ids, ds, sbs) = _one(1, hotWallet, user);
        vm.expectRevert(NormiesCanvasStorageV2.DelegationsSealed.selector);
        storageV2.seedAndFinalizeDelegations(ids, ds, sbs, block.number, block.timestamp);
        vm.expectRevert(NormiesCanvasStorageV2.DelegationsSealed.selector);
        storageV2.seedAndFinalizeDelegations(
            new uint256[](0), new address[](0), new address[](0), block.number, block.timestamp
        );
        assertEq(storageV2.delegates(1), delegate_);
    }

    // ──────────────────────────────────────────────
    //  Cooldown on wallet pixels
    // ──────────────────────────────────────────────

    function testWithdrawnAndBoughtPixelsCoolBeforeTheyCanLeave() public {
        vm.startPrank(address(handler));
        storageV2.creditAttached(1, 100, INormiesCanvasStorageV2.Reason.BurnReward);
        storageV2.detach(1, user, 100, INormiesCanvasStorageV2.Reason.Withdraw); // withdrawn: cools
        assertEq(storageV2.balanceOf(user), 100);
        assertEq(storageV2.availableBalance(user), 0);
        uint64 until = uint64(block.timestamp) + storageV2.DEFAULT_COOLDOWN();
        assertEq(storageV2.unlockAt(user), until);
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasStorageV2.PixelsCoolingDown.selector, user, 0, 1, until));
        storageV2.attach(user, 1, 1, INormiesCanvasStorageV2.Reason.Deposit);
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasStorageV2.PixelsCoolingDown.selector, user, 0, 1, until));
        storageV2.moveBalance(user, buyer, 1);

        vm.warp(until);
        assertEq(storageV2.availableBalance(user), 100);
        storageV2.moveBalance(user, buyer, 40); // bought: cools in the buyer's wallet
        assertEq(storageV2.availableBalance(buyer), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                NormiesCanvasStorageV2.PixelsCoolingDown.selector, buyer, 0, 40, uint64(block.timestamp) + 1 minutes
            )
        );
        storageV2.burnFrom(buyer, 40);
        vm.stopPrank();
    }

    function testOnlyTheNewArrivalsWaitAndRewardsNeverDo() public {
        vm.startPrank(address(handler));
        storageV2.mintTo(user, 50); // a burn reward: spendable at once
        assertEq(storageV2.availableBalance(user), 50);
        storageV2.creditAttached(1, 100, INormiesCanvasStorageV2.Reason.BurnReward);
        storageV2.detach(1, user, 30, INormiesCanvasStorageV2.Reason.Withdraw);
        assertEq(storageV2.availableBalance(user), 50); // the 50 stay spendable, the 30 wait
        storageV2.burnFrom(user, 50);
        vm.warp(block.timestamp + 30 seconds);
        storageV2.detach(1, user, 20, INormiesCanvasStorageV2.Reason.Withdraw); // extends the lock for both lots
        assertEq(storageV2.lockedBalance(user), 50);
        assertEq(storageV2.unlockAt(user), block.timestamp + 1 minutes);
        vm.warp(block.timestamp + 1 minutes);
        assertEq(storageV2.availableBalance(user), 50);
        vm.stopPrank();
    }

    function testMoversNeverCoolAndCooldownIsBoundedPerAddress() public {
        assertEq(storageV2.cooldownOf(address(market)), 0);
        assertEq(storageV2.cooldownOf(user), 1 minutes);
        vm.prank(address(handler));
        storageV2.mintTo(user, 10);
        _cutover();
        vm.prank(user);
        uint256 id = market.list(10, 1 gwei, true, 0); // escrow lands in the market without a cooldown
        assertEq(storageV2.availableBalance(address(market)), 10);
        vm.prank(user);
        market.cancel(id);
        _cool(); // the refund cools like a purchase

        address wrapper = address(0x77A9);
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasStorageV2.CooldownTooLong.selector, 7 days + 1, 7 days));
        storageV2.setCooldown(wrapper, 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasStorageV2.CooldownTooLong.selector, 30, 7 days));
        storageV2.setCooldown(wrapper, 30); // never shorter than the default
        vm.prank(unauthorized);
        vm.expectRevert("Ownable: caller is not the owner");
        storageV2.setCooldown(wrapper, 7 days);
        vm.expectEmit(true, false, false, true);
        emit NormiesCanvasStorageV2.CooldownSet(wrapper, 7 days);
        storageV2.setCooldown(wrapper, 7 days);
        assertEq(storageV2.cooldownOf(wrapper), 7 days);

        vm.prank(address(this));
        storageV2.moveBalance(user, wrapper, 10); // this test contract holds ROLE_CANVAS
        assertEq(storageV2.unlockAt(wrapper), block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days);
        assertEq(storageV2.availableBalance(wrapper), 10); // and then it is free, like anyone else's

        storageV2.setCooldown(wrapper, 0); // back to the default
        assertEq(storageV2.cooldownOf(wrapper), 1 minutes);
    }

    // ──────────────────────────────────────────────
    //  Allowances
    // ──────────────────────────────────────────────

    function testApproveAndUseAllowance() public {
        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit NormiesCanvasStorageV2.Approval(user, buyer, 50);
        storageV2.approve(buyer, 50);
        assertEq(storageV2.allowance(user, buyer), 50);

        vm.prank(unauthorized);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        storageV2.useAllowance(user, buyer, 10);

        vm.startPrank(address(handler));
        storageV2.useAllowance(user, buyer, 30);
        assertEq(storageV2.allowance(user, buyer), 20);
        vm.expectRevert(
            abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAllowance.selector, user, buyer, 20, 21)
        );
        storageV2.useAllowance(user, buyer, 21);
        storageV2.useAllowance(user, user, 1000); // an owner spending their own balance needs no allowance
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(NormiesCanvasStorageV2.ZeroAddress.selector);
        storageV2.approve(address(0), 1);
    }

    function testAllowancePauseBlocksThirdPartiesOnly() public {
        vm.prank(user);
        storageV2.approve(buyer, 50);
        vm.prank(unauthorized);
        vm.expectRevert("Ownable: caller is not the owner");
        storageV2.setAllowancesPaused(true);
        vm.expectEmit(false, false, false, true);
        emit NormiesCanvasStorageV2.AllowancesPausedSet(true);
        storageV2.setAllowancesPaused(true);
        assertTrue(storageV2.allowancesPaused());

        vm.startPrank(address(handler));
        vm.expectRevert(NormiesCanvasStorageV2.AllowancesPaused.selector);
        storageV2.useAllowance(user, buyer, 10);
        storageV2.useAllowance(user, user, 10); // a holder acting alone is unaffected
        vm.stopPrank();
        assertEq(storageV2.allowance(user, buyer), 50); // nothing was consumed

        // Holders can still revoke (or change) while paused.
        vm.prank(user);
        storageV2.approve(buyer, 0);
        assertEq(storageV2.allowance(user, buyer), 0);

        storageV2.setAllowancesPaused(false);
        vm.prank(user);
        storageV2.approve(buyer, 5);
        vm.prank(address(handler));
        storageV2.useAllowance(user, buyer, 5);
        assertEq(storageV2.allowance(user, buyer), 0);
    }

    // ──────────────────────────────────────────────
    //  Balances
    // ──────────────────────────────────────────────

    function testMintMoveBurnTotals() public {
        vm.startPrank(address(handler));
        storageV2.mintTo(user, 100);
        storageV2.moveBalance(user, buyer, 40);
        _cool();
        storageV2.burnFrom(buyer, 10);
        vm.stopPrank();
        assertEq(storageV2.balanceOf(user), 60);
        assertEq(storageV2.balanceOf(buyer), 30);
        assertEq(storageV2.totalWallet(), 90);
    }

    function testInsufficientBalanceReverts() public {
        vm.prank(address(handler));
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientBalance.selector, user, 0, 1));
        storageV2.moveBalance(user, buyer, 1);
    }

    function testAttachDetachTotals() public {
        vm.startPrank(address(handler));
        storageV2.mintTo(user, 100);
        storageV2.attach(user, 7, 60, INormiesCanvasStorageV2.Reason.Deposit);
        assertEq(storageV2.balanceOf(user), 40);
        assertEq(storageV2.attachedOf(7), 60);
        assertEq(storageV2.totalWallet(), 40);
        assertEq(storageV2.totalAttached(), 60);
        storageV2.detach(7, buyer, 25, INormiesCanvasStorageV2.Reason.Withdraw);
        assertEq(storageV2.attachedOf(7), 35);
        assertEq(storageV2.balanceOf(buyer), 25);
        assertEq(storageV2.totalWallet(), 65);
        assertEq(storageV2.totalAttached(), 35);
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasStorageV2.InsufficientAttached.selector, 7, 35, 36));
        storageV2.detach(7, buyer, 36, INormiesCanvasStorageV2.Reason.Withdraw);
        vm.stopPrank();
    }

    function testAttachedChangedEventCarriesPostState() public {
        vm.startPrank(address(handler));
        storageV2.mintTo(user, 10);
        vm.expectEmit(true, false, false, true);
        emit NormiesCanvasStorageV2.AttachedChanged(3, int256(10), 10, uint8(INormiesCanvasStorageV2.Reason.Deposit));
        storageV2.attach(user, 3, 10, INormiesCanvasStorageV2.Reason.Deposit);
        vm.expectEmit(true, false, false, true);
        emit NormiesCanvasStorageV2.AttachedChanged(3, -int256(4), 6, uint8(INormiesCanvasStorageV2.Reason.Spend));
        storageV2.debitAttached(3, 4, INormiesCanvasStorageV2.Reason.Spend);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  Invariant: nothing is created or lost outside mint/burn
    // ──────────────────────────────────────────────

    function invariant_supplyConserved() public view {
        uint256 wallets;
        for (uint256 i; i < 3; i++) {
            wallets += storageV2.balanceOf(handler.actors(i));
        }
        uint256 attached;
        for (uint256 i; i < 3; i++) {
            attached += storageV2.attachedOf(handler.tokens(i));
        }
        assertEq(wallets, storageV2.totalWallet());
        assertEq(attached, storageV2.totalAttached());
        assertEq(wallets + attached, handler.minted() - handler.burned());
    }
}

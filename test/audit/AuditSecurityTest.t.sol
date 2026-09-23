// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import { Test } from "forge-std/src/Test.sol";
import { PixelMarketBase } from "../PixelMarketBase.t.sol";
import { NormiesRevenuePool } from "../../src/NormiesRevenuePool.sol";
import { NormiesCanvasStorageV2 } from "../../src/NormiesCanvasStorageV2.sol";
import { NormiesPixelMarket } from "../../src/NormiesPixelMarket.sol";
import { INormiesCanvasStorageV2 } from "../../src/interfaces/INormiesCanvasStorageV2.sol";
import { IWETH } from "../../src/interfaces/IWETH.sol";
import { MockWETH } from "../mocks/MockWETH.sol";
import { PoolHandler } from "../NormiesRevenuePoolTest.t.sol";

/// @notice Reproductions assert current behavior; passing does not mean an issue is fixed.
contract AuditSecurityTest is PixelMarketBase {
    function setUp() public override {
        cutoverInSetUp = false;
        super.setUp();
        _mintRealTo(user, 1);
        // Fixture state before attack scenarios; no scenario mints/remints NFTs.
        storageV2.creditAttached(1, 100, INormiesCanvasStorageV2.Reason.Migration);
    }

    function _seed(address d, address setBy) internal {
        uint256[] memory ids = new uint256[](1);
        address[] memory ds = new address[](1);
        address[] memory owners = new address[](1);
        ids[0] = 1;
        ds[0] = d;
        owners[0] = setBy;
        storageV2.seedDelegations(ids, ds, owners);
    }

    /// @notice Regression: V2 changes only begin after the delegation snapshot is sealed.
    function testAudit_PreCutoverRevocationCannotBeOverwritten() public {
        vm.prank(user);
        canvasV1.setDelegate(1, delegate_);
        vm.prank(user);
        vm.expectRevert(NormiesCanvasStorageV2.DelegationsNotFinalized.selector);
        canvas.revokeDelegate(1);
        _seed(canvasV1.delegates(1), canvasV1.delegateSetBy(1));
        _cutover();
        vm.prank(user);
        canvas.revokeDelegate(1);
        vm.expectRevert(NormiesCanvasStorageV2.DelegationsSealed.selector);
        _seed(delegate_, user);
        assertEq(storageV2.delegates(1), address(0));
    }

    /// @notice Clarified policy: V1 revocations after the script's snapshot do not change the V2 copy.
    function testAudit_PostSnapshotV1RevocationDoesNotChangeV2() public {
        vm.prank(user);
        canvasV1.setDelegate(1, delegate_);
        address snapshotDelegate = canvasV1.delegates(1);
        address snapshotOwner = canvasV1.delegateSetBy(1);
        vm.prank(user);
        canvasV1.revokeDelegate(1);
        _seed(snapshotDelegate, snapshotOwner);
        _cutover();
        vm.prank(delegate_);
        canvas.setTransformBitmap(1, _bitmapWithPixels(1, 40));
        assertEq(canvas.lockedPixels(1), 1);
    }

    function testAudit_NftRoundTripTransfersPixelsWithoutMarketFees() public {
        _cutover();
        vm.prank(user);
        normies.transferFrom(user, buyer, 1);
        vm.startPrank(buyer);
        canvas.withdrawPixels(1, 100, true);
        normies.transferFrom(buyer, user, 1);
        vm.stopPrank();
        assertEq(normies.ownerOf(1), user);
        assertEq(storageV2.balanceOf(buyer), 100);
        assertEq(storageV2.attachedOf(1), 0);
        assertEq(feeTreasury.balance + revShare.balance, 0);
        assertEq(market.nextListingId(), 1);
    }

    function testAudit_DirectNftBurnOrphansAttachedPixels() public {
        _cutover();
        vm.prank(user);
        normies.burn(1);
        assertEq(storageV2.attachedOf(1), 100);
        assertEq(storageV2.totalAttached(), 100);
        vm.prank(user);
        vm.expectRevert();
        canvas.withdrawPixels(1, 100, true);
    }

    function testAudit_AllowanceOverwriteHasStandardReplacementRace() public {
        _cutover();
        storageV2.mintTo(user, 300);
        vm.prank(user);
        storageV2.approve(delegate_, 100);
        vm.prank(delegate_);
        market.listFrom(user, 100, 1, true, 0);
        vm.prank(user);
        storageV2.approve(delegate_, 50);
        vm.prank(delegate_);
        market.listFrom(user, 50, 1, true, 0);
        assertEq(storageV2.balanceOf(user), 150);
    }

    function testAudit_DuplicateBatchOverfillRollsBackEverything() public {
        _cutover();
        storageV2.mintTo(user, 100);
        vm.prank(user);
        uint256 id = market.list(100, 1 gwei, true, 0);
        uint256[] memory ids = new uint256[](2);
        uint32[] memory amounts = new uint32[](2);
        ids[0] = id;
        ids[1] = id;
        amounts[0] = 60;
        amounts[1] = 60;
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(NormiesPixelMarket.InvalidAmount.selector, 60, 40));
        market.batchBuy{ value: 120 gwei }(ids, amounts);
        assertEq(storageV2.balanceOf(buyer), 0);
        assertEq(storageV2.balanceOf(address(market)), 100);
        assertEq(market.getListing(id).remaining, 100);
        assertEq(user.balance + feeTreasury.balance + revShare.balance, 0);
    }

    function testAudit_RoundTripOwnershipReactivatesLocalDelegate() public {
        _cutover();
        vm.prank(user);
        canvas.setDelegate(1, delegate_);
        vm.prank(user);
        normies.transferFrom(user, buyer, 1);
        vm.prank(buyer);
        normies.transferFrom(buyer, user, 1);
        vm.prank(delegate_);
        canvas.setTransformBitmap(1, _bitmapWithPixels(1, 40));
        assertEq(canvas.lockedPixels(1), 1);
    }
}

contract AuditPoolChecksTest is Test {
    NormiesRevenuePool pool;

    function setUp() public {
        pool = new NormiesRevenuePool(IWETH(address(new MockWETH())));
        vm.roll(1000);
        vm.warp(1_800_000_000);
    }

    function testAudit_InvariantHandlerPostsWithOwnershipAndSurfacesFailures() public {
        PoolHandler handler = new PoolHandler(pool);
        handler.deposit(5 ether);
        vm.expectRevert("Ownable: caller is not the owner");
        handler.post(1 ether, 1 ether, 1 ether);
        pool.transferOwnership(address(handler));
        handler.post(1 ether, 1 ether, 1 ether);
        assertEq(pool.nextEpochId(), 2);
        assertEq(pool.outstanding(), 3 ether);
        assertEq(handler.posts(), 1);
    }

    function testFuzzAudit_ClaimBitmapAndDomain(uint256 index, uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 10 ether);
        address account = address(0xA11CE);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), index, account, amount))));
        vm.deal(address(pool), amount * 2);
        pool.postEpoch(leaf, amount, 100, 900, bytes32(0), "");
        pool.postEpoch(leaf, amount, 901, 999, bytes32(0), "");
        vm.expectRevert(NormiesRevenuePool.InvalidProof.selector);
        pool.claim(2, index, account, amount, new bytes32[](0));
        pool.claim(1, index, account, amount, new bytes32[](0));
        assertTrue(pool.isClaimed(1, index));
        assertFalse(pool.isClaimed(1, index ^ 1));
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.AlreadyClaimed.selector, 1, index));
        pool.claim(1, index, account, amount, new bytes32[](0));
        assertEq(account.balance, amount);
        assertEq(pool.outstanding(), amount);
    }
}

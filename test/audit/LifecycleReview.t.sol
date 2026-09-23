// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { PixelMarketBase } from "../PixelMarketBase.t.sol";
import { NormiesCanvasV2 } from "../../src/NormiesCanvasV2.sol";
import { NormiesCanvasStorageV2 } from "../../src/NormiesCanvasStorageV2.sol";
import { NormiesRevenuePool } from "../../src/NormiesRevenuePool.sol";
import { INormiesCanvasV2 } from "../../src/interfaces/INormiesCanvasV2.sol";
import { INormiesCanvasStorageV2 } from "../../src/interfaces/INormiesCanvasStorageV2.sol";
import { INormiesStorage } from "../../src/interfaces/INormiesStorage.sol";
import { IWETH } from "../../src/interfaces/IWETH.sol";
import { MockWETH } from "../mocks/MockWETH.sol";

/// @notice These tests document current behavior and do not assert remediation.
contract LifecycleReviewTest is PixelMarketBase {
    function testPendingBurnNeedsOldCanvasRoleAfterReplacement() public {
        _mintRealTo(user, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.startPrank(user);
        normies.setApprovalForAll(address(canvas), true);
        canvas.commitBurnToWallet(ids);
        vm.stopPrank();
        NormiesCanvasV2 replacement = new NormiesCanvasV2(
            address(normies), INormiesStorage(address(normiesStorage)), INormiesCanvasStorageV2(address(storageV2))
        );
        storageV2.setMoverRoles(address(replacement), storageV2.ROLE_CANVAS());
        storageV2.setMoverRoles(address(canvas), 0);
        replacement.setPaused(false);
        vm.roll(block.number + 6);
        vm.expectRevert(NormiesCanvasV2.CommitmentNotFound.selector);
        replacement.revealBurn(0);
        vm.expectRevert(NormiesCanvasStorageV2.NotAuthorized.selector);
        canvas.revealBurn(0);
        assertEq(storageV2.balanceOf(user), 0);
        storageV2.setMoverRoles(address(canvas), storageV2.ROLE_CANVAS());
        canvas.revealBurn(0);
        assertGt(storageV2.balanceOf(user), 0);
    }

    function testDirectBurnAndPrivilegedRemintRetainPaidCanvasState() public {
        _mintRealTo(user, 1);
        storageV2.creditAttached(1, 1200, INormiesCanvasStorageV2.Reason.Migration);
        vm.startPrank(user);
        canvas.enlargeCanvas(1, 50, INormiesCanvasV2.PaySource.Attached, false);
        canvas.clearBase(1, INormiesCanvasV2.PaySource.Attached, false);
        canvas.setTransformBitmap(1, _bitmapWithPixels(10, 50));
        normies.burn(1);
        vm.stopPrank();
        assertEq(storageV2.attachedOf(1), 100);
        assertEq(storageV2.totalAttached(), 100);
        vm.prank(user);
        vm.expectRevert();
        canvas.withdrawPixels(1, 100, true);
        // Remint is explicitly privileged; it is not a public entry point.
        _mintRealTo(buyer, 1);
        assertEq(canvas.gridSize(1), 50);
        assertTrue(canvas.baseCleared(1));
        assertTrue(storageV2.isTransformed(1));
        vm.prank(buyer);
        canvas.withdrawPixels(1, 100, true);
        assertEq(storageV2.balanceOf(buyer), 100);
    }

    function testRewardParametersChangeAfterIrreversibleBurn() public {
        _mintRevealedTo(user, 1, _bitmapWithPixels(1600, 40));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.startPrank(user);
        normies.setApprovalForAll(address(canvas), true);
        canvas.commitBurnToWallet(ids);
        vm.stopPrank();
        uint256[] memory thresholds = new uint256[](0);
        uint256[] memory minimums = new uint256[](1);
        canvas.setBurnTiers(thresholds, minimums);
        canvas.setMaxBurnPercent(0);
        vm.roll(block.number + 6);
        canvas.revealBurn(0);
        assertEq(storageV2.balanceOf(user), 0);
        vm.expectRevert();
        normies.ownerOf(1);
    }
}

contract PoolWindowReviewTest is Test {
    function testOwnerCannotReleaseOrWithdrawExistingEpochReservesEarly() public {
        NormiesRevenuePool pool = new NormiesRevenuePool(IWETH(address(new MockWETH())));
        address holder = address(0xA11CE);
        address treasury = address(0xFEE);
        vm.roll(1000);
        vm.warp(1_800_000_000);
        vm.deal(address(pool), 1 ether);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), uint256(0), holder, uint256(1 ether)))));
        pool.postEpoch(leaf, 1 ether, 1, 999, bytes32(0), "");
        uint256 deadline = pool.getEpoch(1).sweepableAt;
        assertEq(deadline, block.timestamp + 365 days);
        uint64 minimum = pool.MIN_CLAIM_WINDOW();
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowTooShort.selector, 0, minimum));
        pool.setClaimWindow(0);
        pool.setClaimWindow(minimum);
        vm.warp(block.timestamp + minimum);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, 1));
        pool.sweep(1);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.InsufficientUnallocated.selector, 0, 1 ether));
        pool.withdrawUnallocated(treasury, 1 ether);
        assertEq(pool.outstanding(), 1 ether);
        assertEq(pool.getEpoch(1).sweepableAt, deadline);
        pool.claim(1, 0, holder, 1 ether, new bytes32[](0));
        assertEq(holder.balance, 1 ether);
        assertEq(treasury.balance, 0);
    }
}

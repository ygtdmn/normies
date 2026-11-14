// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "../PixelMarketBase.t.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../src/NormiesArenaQueue.sol";
import { NormiesArenaSkins } from "../../src/NormiesArenaSkins.sol";
import { NormiesArena } from "../../src/NormiesArena.sol";
import { ArenaIdentityMock } from "./ArenaTestBase.sol";

/// @notice The Arena against the real pixel ledger (NormiesCanvasStorageV2) rather than a mock.
contract NormiesArenaLedgerTest is PixelMarketBase {
    NormiesArenaStorage store;
    NormiesArenaQueue queue;
    NormiesArenaSkins skins;
    NormiesArena arena;
    ArenaIdentityMock identity;

    function setUp() public override {
        super.setUp();
        identity = new ArenaIdentityMock();
        identity.setOwner(1, user);
        identity.bind(1, 1);
        store = new NormiesArenaStorage(
            address(storageV2), address(identity), address(identity), address(delegateV2), address(delegateV1), owner
        );
        arena = new NormiesArena(address(store), owner);
        queue = new NormiesArenaQueue(address(store), owner);
        skins = new NormiesArenaSkins(address(store), owner, feeTreasury);
        store.setAuthorizedWriter(address(arena), true);
        store.setAuthorizedWriter(address(queue), true);
        store.setAuthorizedWriter(address(skins), true);
        vm.prank(user);
        queue.bindAgent(1, 1);
        storageV2.setMoverRoles(address(store), storageV2.ROLE_WRAPPER());
        storageV2.setMoverRoles(address(queue), storageV2.ROLE_WRAPPER());
        storageV2.setMoverRoles(address(skins), storageV2.ROLE_WRAPPER());
        queue.setPaused(false);
        skins.setPaused(false);
        storageV2.mintTo(user, 100);
    }

    function testDepositWithdrawAndCooldown() public {
        vm.prank(user);
        queue.deposit(1, 10, true);
        assertEq(storageV2.balanceOf(user), 90);
        assertEq(storageV2.balanceOf(address(store)), 10);
        assertEq(storageV2.balanceOf(address(queue)), 0);
        vm.prank(user);
        store.withdraw(1, 10);
        // The withdrawn pixels cool down in the holder's wallet before they can move again.
        assertEq(storageV2.availableBalance(user), 90);
        vm.prank(user);
        vm.expectRevert();
        queue.deposit(1, 100, false);
        vm.warp(block.timestamp + 61);
        vm.prank(user);
        queue.deposit(1, 100, false);
    }

    function testSkinPaidThroughALedgerAllowance() public {
        vm.prank(user);
        storageV2.approve(buyer, 5);
        vm.prank(buyer);
        skins.purchase(1, 5, user);
        assertEq(storageV2.balanceOf(feeTreasury), 5);
        assertEq(storageV2.balanceOf(user), 95);
        assertEq(storageV2.allowance(user, buyer), 0);
        assertEq(store.purchased(1), 1);
        vm.prank(buyer);
        vm.expectRevert();
        skins.purchase(1, 5, user);
    }

    function testLogicContractsCannotMint() public {
        vm.prank(address(queue));
        vm.expectRevert();
        storageV2.mintTo(user, 1);
        assertEq(storageV2.moverRoles(address(arena)), 0);
    }

    /// @notice The worst wallet batch (MAX_BATCH registered deposits), storage cold, stays under the per-transaction gas cap.
    function testMaxBatchDepositGas() public {
        uint256 n = queue.MAX_BATCH();
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256[] memory agentIds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = i + 10;
            amounts[i] = 1;
            agentIds[i] = i + 10;
            identity.setOwner(i + 10, user);
            identity.bind(i + 10, i + 10);
        }
        vm.cool(address(storageV2));
        vm.cool(address(store));
        vm.cool(address(queue));
        vm.cool(address(identity));
        vm.cool(address(delegateV2));
        vm.prank(user);
        uint256 before = gasleft();
        queue.depositRegisteredBatch(ids, amounts, agentIds);
        uint256 used = before - gasleft();
        emit log_named_uint("MAX_BATCH depositRegisteredBatch gas, cold", used);
        assertLt(used, 14_000_000);
    }

    function testSweepTakesOnlySurplus() public {
        vm.prank(user);
        queue.deposit(1, 10, true);
        storageV2.mintTo(address(store), 3);
        assertEq(store.surplus(), 3);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.sweep(owner, 4);
        store.sweep(owner, 3);
        assertEq(storageV2.balanceOf(address(store)), 10);
    }
}

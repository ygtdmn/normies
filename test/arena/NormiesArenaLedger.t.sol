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
        queue.deposit(1, 10);
        assertEq(storageV2.balanceOf(user), 90);
        assertEq(storageV2.balanceOf(address(store)), 10);
        assertEq(storageV2.balanceOf(address(queue)), 0);
        vm.prank(user);
        store.withdraw(1, 10);
        // The withdrawn pixels cool down in the holder's wallet before they can move again.
        assertEq(storageV2.availableBalance(user), 90);
        vm.prank(user);
        vm.expectRevert();
        queue.deposit(1, 100);
        vm.warp(block.timestamp + 61);
        vm.prank(user);
        queue.deposit(1, 100);
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

    /// @notice The worst storage batch on the real ledger: MAX_BATCH withdrawals to distinct fresh holders, half of
    ///         them from short Normies that each dropped out in a different round over 520 rounds. RUN WITH
    ///         --isolate for the real figure (see test/audit/arena/ArenaGas.t.sol).
    function testMaxBatchWithdrawGas() public {
        uint256 n = store.MAX_BATCH();
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        storageV2.mintTo(user, 1_000_000);
        for (uint256 i; i < n; ++i) {
            uint256 id = i + 200;
            ids[i] = id;
            amounts[i] = i % 2 == 0 ? 1 : 3;
            identity.setOwner(id, user);
            identity.bind(id, id);
            vm.prank(user);
            queue.bindAgent(id, id);
            vm.prank(user);
            queue.deposit(id, i % 2 == 0 ? 2 * i + 3 : 5000 + i * 16);
            // Each Normie then changes hands, so every withdrawal pays a fresh holder.
            identity.setOwner(id, address(uint160(0xF000 + i)));
            delegateV2.delegateAll(user, address(uint160(0xF000 + i)), true);
        }
        arena.setEntryPrice(2);
        arena.setFreeRound(1, false);
        arena.setFreeRound(2, false);
        arena.setPaused(false);
        for (uint256 r = 1; r <= 520; ++r) {
            arena.startRound(r);
            arena.endRound(r, none, none, none);
        }
        assertEq(store.stateOf(200), 2);
        _measure(
            "MAX_BATCH withdrawBatch, real ledger, fresh holders, half lazily short",
            user,
            address(store),
            abi.encodeCall(store.withdrawBatch, (ids, amounts))
        );
    }

    uint256[] none;

    function _measure(string memory name, address caller, address target, bytes memory data) internal {
        uint256 cap = 16_777_216;
        uint256 snap = vm.snapshotState();
        vm.prank(caller);
        (bool ok,) = target.call{ gas: cap - 21_000 }(data);
        assertTrue(ok, "must succeed with a gas limit equal to the cap");
        vm.revertToState(snap);
        uint256 lo = 1;
        uint256 hi = cap - 21_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            snap = vm.snapshotState();
            vm.prank(caller);
            (ok,) = target.call{ gas: mid }(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        emit log_string(name);
        emit log_named_uint("  MIN TX GAS LIMIT", lo + 21_000);
        assertLt(lo + 21_000, cap);
    }

    function testSweepTakesOnlySurplus() public {
        vm.prank(user);
        queue.deposit(1, 10);
        storageV2.mintTo(address(store), 3);
        assertEq(store.surplus(), 3);
        vm.expectRevert(NormiesArenaStorage.InvalidInput.selector);
        store.sweep(owner, 4);
        store.sweep(owner, 3);
        assertEq(storageV2.balanceOf(address(store)), 10);
    }
}

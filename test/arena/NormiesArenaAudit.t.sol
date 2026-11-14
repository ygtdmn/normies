// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { NormiesArena } from "../../src/NormiesArena.sol";
import { NormiesArenaQueue } from "../../src/NormiesArenaQueue.sol";
import { NormiesArenaSkins } from "../../src/NormiesArenaSkins.sol";
import { ArenaAccess } from "../../src/arena/ArenaAccess.sol";
import { DeployArena } from "../../script/DeployArena.s.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";

contract StrayToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Stray";
    }

    function symbol() public pure override returns (string memory) {
        return "STR";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A short Normie's top-up needs a matching agent link, 0xdEaD counts as burned, and Lifebuoy rescue.
contract NormiesArenaAuditTest is ArenaTestBase {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev Normie 1 (alice, 4 pixels) taken out short of funds by paid round 2 at price 5.
    function _short() private {
        arena.setFreeRound(2, false);
        arena.setEntryPrice(5);
        join(1, alice, 4);
        admitAll(1);
        admitAll(2);
        assertTrue(shortOfFunds(1));
        assertFalse(inLine(1));
    }

    function testAShortNormiesTopUpNeedsAMatchingAgentLink() public {
        _short();
        identity.bind(1, 2);
        // Both kinds of top-up revert while the binding no longer points at the Normie.
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        queue.deposit(1, 1, false);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidState.selector);
        queue.deposit(1, 1, true);
        assertEq(store.balanceOf(1), 4);
        // With the binding back, either one returns it to the line.
        identity.bind(1, 1);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        queue.deposit(1, 1, false);
        assertTrue(inLine(1));
        assertTrue(vm.revertToState(snap));
        vm.prank(alice);
        queue.deposit(1, 1, true);
        assertTrue(inLine(1));
    }

    function testATopUpOfANormieOutOfLineByHandNeedsNoLink() public {
        join(1, alice, 10);
        vm.prank(alice);
        queue.pause(1);
        identity.bind(1, 2);
        vm.prank(alice);
        queue.deposit(1, 1, false);
        assertEq(store.balanceOf(1), 11);
        assertFalse(inLine(1));
    }

    function testANormieHeldByDeadIsBurned() public {
        join(1, alice, 10);
        join(2, bob, 10);
        identity.setOwner(1, DEAD);
        assertTrue(store.isBurned(1));
        assertFalse(store.isBurned(2));
        // It is skipped at admission and leaves the line for good.
        admitAll(1);
        assertEq(arena.players(1).length, 1);
        assertEq(arena.players(1)[0], 2);
        assertFalse(inLine(1));
        // Nobody can act for it, not even the DEAD address.
        vm.prank(DEAD);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        store.withdraw(1, 1);
        vm.prank(alice);
        vm.expectRevert(NormiesArenaStorage.Burned.selector);
        queue.deposit(1, 1, false);
        vm.prank(alice);
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        skins.purchase(1, 5, alice);
        // The owner rescues its balance.
        store.rescue(1, treasury);
        assertEq(ledger.balanceOf(treasury), 10);
        assertEq(store.balanceOf(1), 0);
        assertBacked();
    }

    function testANormieHeldByTheArenaIsNotBurned() public {
        identity.setOwner(1, address(store));
        identity.setOwner(2, address(queue));
        assertFalse(store.isBurned(1));
        assertFalse(store.isBurned(2));
        vm.expectRevert(NormiesArenaStorage.NotBurned.selector);
        store.rescue(1, treasury);
    }

    function testDeployScriptLeavesRescueToTheOwnerOnly() public {
        address admin = address(0xAD);
        vm.setEnv("ARENA_PIXELS", vm.toString(address(ledger)));
        vm.setEnv("ARENA_COLLECTION", vm.toString(address(identity)));
        vm.setEnv("ARENA_ADAPTER", vm.toString(address(identity)));
        vm.setEnv("ARENA_ADMIN", vm.toString(admin));
        vm.setEnv("ARENA_TREASURY", vm.toString(treasury));
        vm.setEnv("ARENA_DELEGATE_REGISTRY", vm.toString(address(registry)));
        vm.setEnv("ARENA_DELEGATE_REGISTRY_V1", vm.toString(address(registryV1)));
        DeployArena script = new DeployArena();
        (NormiesArenaStorage s, NormiesArena a, NormiesArenaQueue q, NormiesArenaSkins k) = script.run();
        // The broadcaster in a script run is tx.origin, Lifebuoy's deployer.
        address deployer = tx.origin;
        address[4] memory targets = [address(s), address(a), address(q), address(k)];
        StrayToken token = new StrayToken();
        for (uint256 i; i < 4; ++i) {
            Lifebuoy target = Lifebuoy(payable(targets[i]));
            assertEq(target.rescueLocked() & 1, 1);
            token.mint(targets[i], 10);
            vm.prank(deployer);
            vm.expectRevert(Lifebuoy.RescueUnauthorizedOrLocked.selector);
            target.rescueERC20(address(token), deployer, 10);
            vm.prank(admin);
            target.rescueERC20(address(token), admin, 10);
            assertEq(token.balanceOf(targets[i]), 0);
        }
        assertEq(token.balanceOf(admin), 40);
    }

    function testLifebuoyCannotMoveCustody() public {
        join(1, alice, 10);
        // The pixel ledger has no ERC-20 transfer, so a rescue of it reverts and the balances stay backed.
        vm.expectRevert();
        store.rescueERC20(address(ledger), address(this), 10);
        assertEq(ledger.balanceOf(address(store)), 210);
        assertBacked();
    }

    /// @notice Right after DeployArena every logic contract is paused: a holder cannot deposit, join or buy a skin
    ///         until the owner (or a guardian) unpauses. Withdrawals have no pause.
    function testDeployScriptLeavesEverythingPaused() public {
        address admin = address(0xAD);
        vm.setEnv("ARENA_PIXELS", vm.toString(address(ledger)));
        vm.setEnv("ARENA_COLLECTION", vm.toString(address(identity)));
        vm.setEnv("ARENA_ADAPTER", vm.toString(address(identity)));
        vm.setEnv("ARENA_ADMIN", vm.toString(admin));
        vm.setEnv("ARENA_TREASURY", vm.toString(treasury));
        vm.setEnv("ARENA_DELEGATE_REGISTRY", vm.toString(address(registry)));
        vm.setEnv("ARENA_DELEGATE_REGISTRY_V1", vm.toString(address(registryV1)));
        (NormiesArenaStorage s, NormiesArena a, NormiesArenaQueue q, NormiesArenaSkins k) = new DeployArena().run();
        assertTrue(a.paused() && q.paused() && k.paused());
        // Wired as the launch checklist does it, but still paused.
        vm.startPrank(admin);
        s.setAuthorizedWriter(address(a), true);
        s.setAuthorizedWriter(address(q), true);
        s.setAuthorizedWriter(address(k), true);
        vm.stopPrank();
        ledger.authorize(address(s));
        ledger.authorize(address(q));
        ledger.authorize(address(k));
        give(1, alice);
        vm.startPrank(alice);
        vm.expectRevert(ArenaAccess.Paused.selector);
        q.deposit(1, 5, true);
        vm.expectRevert(ArenaAccess.Paused.selector);
        q.deposit(1, 5, false);
        vm.expectRevert(ArenaAccess.Paused.selector);
        q.depositRegisteredBatch(ids1(1), ids1(5), ids1(1));
        vm.expectRevert(ArenaAccess.Paused.selector);
        q.resume(1);
        vm.expectRevert(ArenaAccess.Paused.selector);
        q.resumeRegisteredBatch(ids1(1), ids1(1));
        vm.expectRevert(ArenaAccess.Paused.selector);
        k.purchase(1, 5, alice);
        vm.stopPrank();
        vm.prank(admin);
        vm.expectRevert(ArenaAccess.Paused.selector);
        a.startRound(1);
        // A stranger cannot unpause; the owner can.
        vm.prank(alice);
        vm.expectRevert();
        q.setPaused(false);
        vm.startPrank(admin);
        q.setPaused(false);
        k.setPaused(false);
        vm.stopPrank();
        vm.startPrank(alice);
        q.depositRegisteredBatch(ids1(1), ids1(5), ids1(1));
        k.purchase(1, 5, alice);
        vm.stopPrank();
        assertEq(s.balanceOf(1), 5);
        (, bool active,) = s.enrollment(1);
        assertTrue(active);
        // Withdrawals work whatever the pause switches say.
        vm.prank(admin);
        q.setPaused(true);
        vm.prank(alice);
        s.withdraw(1, 5);
        assertEq(s.balanceOf(1), 0);
    }
}

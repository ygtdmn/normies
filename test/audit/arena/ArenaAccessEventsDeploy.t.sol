// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ArenaAuditBase } from "./ArenaAuditBase.sol";
import { NormiesArenaStorage } from "../../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../../../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../../../src/NormiesArenaSkins.sol";
import { DeployArena } from "../../../script/DeployArena.s.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice Access-control matrix, event contents, and the deploy script followed step by step.
contract ArenaAccessEventsDeployTest is ArenaAuditBase {
    event Deposited(uint256 indexed id, address indexed from, uint256 amount);
    event Withdrawn(uint256 indexed id, address indexed to, uint256 amount);
    event Rescued(uint256 indexed id, address indexed to, uint256 amount);
    event Charged(uint256 indexed round, uint256 indexed id, uint256 amount);
    event Credited(uint256 indexed round, uint256 indexed id, uint256 amount);
    event Sponsored(uint256 indexed round, address indexed from, uint256 amount);
    event SponsorshipMoved(uint256 indexed from, uint256 indexed to, uint256 amount);
    event SponsorshipReleased(uint256 indexed round, address indexed to, uint256 amount);
    event Enrolled(uint256 indexed id, uint64 ticket);
    event EnrollmentPaused(uint256 indexed id, bool needsFunds);
    event AgentLinked(uint256 indexed id, uint256 indexed agentId);
    event RulesFixed(uint256 indexed round, uint256 capacity, uint256 price, uint256 winnerBps, bool free);
    event RoundStarted(uint256 indexed round, uint64 ticketCutoff, uint256 at);
    event Admitted(uint256 indexed round, uint256 indexed id);
    event AdmissionsClosed(uint256 indexed round, uint256 participants);
    event RoundFinished(uint256 indexed round, uint256 players, uint256 at);
    event ResultsPosted(uint256 indexed round, bytes32 indexed resultHash);
    event Settled(uint256 indexed round, bytes32 indexed resultHash, uint256 pool);
    event Cancelled(uint256 indexed round, uint256 refunded, uint256 carriedTo);
    event SkinPurchased(uint256 indexed purchaseId, uint256 indexed id, address indexed buyer, uint256 price);

    // ───────────── access matrix ─────────────

    struct Call {
        address target;
        bytes data;
        // Bit 1 operator, 2 arena guardian, 4 sponsor wallet may call it (the owner always may).
        uint8 allowed;
    }

    function _calls() internal view returns (Call[] memory c) {
        uint256[] memory none = new uint256[](0);
        c = new Call[](27);
        c[0] = Call(address(store), abi.encodeCall(store.setAuthorizedWriter, (address(1), true)), 0);
        c[1] = Call(address(store), abi.encodeCall(store.setAdapter, (address(1))), 0);
        c[2] = Call(address(store), abi.encodeCall(store.sweep, (address(1), 1)), 0);
        c[3] = Call(address(store), abi.encodeCall(store.rescue, (1, address(1))), 0);
        c[4] = Call(address(store), abi.encodeCall(store.grantRoles, (address(1), 1)), 0);
        c[5] = Call(address(store), abi.encodeCall(store.transferOwnership, (address(1))), 0);
        c[6] = Call(address(arena), abi.encodeCall(arena.setCapacity, (5)), 0);
        c[7] = Call(address(arena), abi.encodeCall(arena.setEntryPrice, (5)), 0);
        c[8] = Call(address(arena), abi.encodeCall(arena.setWinnerBps, (5)), 0);
        c[9] = Call(address(arena), abi.encodeCall(arena.setMaxScan, (5)), 0);
        c[10] = Call(address(arena), abi.encodeCall(arena.setFreeRound, (9, true)), 0);
        c[11] = Call(address(arena), abi.encodeCall(arena.releaseSponsorship, (9, address(1), 1)), 0);
        c[12] = Call(address(arena), abi.encodeCall(arena.settle, (1, bytes32(uint256(1)), none)), 0);
        c[13] = Call(address(arena), abi.encodeCall(arena.grantRoles, (address(1), 8)), 0);
        c[14] = Call(address(arena), abi.encodeCall(arena.startRound, (1)), 1);
        c[15] = Call(address(arena), abi.encodeCall(arena.admit, (1, 1)), 1);
        c[16] = Call(address(arena), abi.encodeCall(arena.finishRound, (1)), 1);
        c[17] = Call(address(arena), abi.encodeCall(arena.invalidateEnrollment, (1, 1)), 1);
        c[18] = Call(address(arena), abi.encodeCall(arena.postResults, (1, bytes32(uint256(1)))), 1);
        c[19] = Call(address(arena), abi.encodeCall(arena.cancel, (1)), 2);
        c[20] = Call(address(arena), abi.encodeCall(arena.setPaused, (false)), 2);
        c[21] = Call(address(queue), abi.encodeCall(queue.setPaused, (false)), 0);
        c[22] = Call(address(queue), abi.encodeCall(queue.setMaxBatch, (5)), 0);
        c[23] = Call(address(queue), abi.encodeCall(queue.sponsor, (9, 1)), 4);
        c[24] = Call(address(skins), abi.encodeCall(skins.setPaused, (false)), 0);
        c[25] = Call(address(skins), abi.encodeCall(skins.setPrice, (5)), 0);
        c[26] = Call(address(skins), abi.encodeCall(skins.setTreasury, (address(1))), 0);
    }

    /// @notice Every privileged entry point, called by a stranger and by each role holder: refused with Unauthorized
    ///         unless that role is the one the function names. Roles are per contract: the Arena's guardian cannot
    ///         pause the queue or the skins, the queue's sponsor can do nothing else.
    function test_access_matrix() public {
        sponsorFreeRounds();
        Call[] memory c = _calls();
        address[4] memory who = [address(0xBEEF), operator, guardian, sponsorWallet];
        uint8[4] memory bit = [0, 1, 2, 4];
        for (uint256 w; w < 4; ++w) {
            for (uint256 i; i < c.length; ++i) {
                uint256 snap = vm.snapshotState();
                vm.prank(who[w]);
                (bool ok, bytes memory ret) = c[i].target.call(c[i].data);
                bool unauthorized = !ok && ret.length >= 4 && bytes4(ret) == Ownable.Unauthorized.selector;
                if (c[i].allowed & bit[w] != 0) assertFalse(unauthorized, "role holder refused");
                else assertTrue(unauthorized, "call not refused");
                vm.revertToState(snap);
            }
        }
        // The owner is refused nowhere.
        for (uint256 i; i < c.length; ++i) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = c[i].target.call(c[i].data);
            assertFalse(!ok && ret.length >= 4 && bytes4(ret) == Ownable.Unauthorized.selector);
            vm.revertToState(snap);
        }
    }

    /// @notice Roles granted on the storage itself give nothing: its privileged functions are owner or writer only.
    function test_access_rolesOnStorageGiveNothing() public {
        store.grantRoles(carol, type(uint256).max);
        vm.startPrank(carol);
        vm.expectRevert(Ownable.Unauthorized.selector);
        store.setAuthorizedWriter(carol, true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        store.sweep(carol, 1);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        store.addBalance(1, carol, 1);
        vm.stopPrank();
    }

    // ───────────── events ─────────────

    function _expect() internal {
        vm.expectEmit(true, true, true, true, address(store));
    }

    /// @notice The storage's events through a whole paid round, a settlement, a cancellation, a withdrawal by a
    ///         delegate, a rescue and a skin purchase: emitter, order and every argument.
    function test_events_lifecycle() public {
        arena.setFreeRound(1, false);
        arena.setFreeRound(2, false);
        arena.setEntryPrice(5);
        give(1, alice);
        give(2, bob);

        _expect();
        emit Sponsored(1, sponsorWallet, 100);
        vm.prank(sponsorWallet);
        queue.sponsor(1, 100);

        _expect();
        emit AgentLinked(1, 1);
        vm.prank(normies.ownerOf(1));
        queue.bindAgent(1, 1);
        vm.prank(normies.ownerOf(2));
        queue.bindAgent(2, 2);

        // A delegate tops up: `from` is the delegate (the wallet that paid).
        regV2.delegateAll(hot, alice, true);
        _expect();
        emit Deposited(1, hot, 5);
        _expect();
        emit Enrolled(1, 1);
        vm.prank(hot);
        queue.deposit(1, 5, true);
        vm.prank(bob);
        queue.deposit(2, 20, true);

        _expect();
        emit RulesFixed(1, 200, 5, 1000, false);
        _expect();
        emit RoundStarted(1, 2, block.timestamp);
        arena.startRound(1);

        _expect();
        emit Charged(1, 1, 5);
        _expect();
        emit Admitted(1, 1);
        _expect();
        emit Enrolled(1, 3);
        _expect();
        emit Charged(1, 2, 5);
        _expect();
        emit Admitted(1, 2);
        _expect();
        emit Enrolled(2, 4);
        _expect();
        emit AdmissionsClosed(1, 2);
        arena.admit(1, 50);

        _expect();
        emit RoundFinished(1, 2, block.timestamp);
        arena.finishRound(1);

        bytes32 h = keccak256("r");
        _expect();
        emit ResultsPosted(1, h);
        arena.postResults(1, h);

        // Round 2: Normie 1 is short and leaves the line; Normie 2 is seated.
        arena.startRound(2);
        _expect();
        emit EnrollmentPaused(1, true);
        arena.admit(2, 50);

        // Settle round 1 for Normie 1: credited, returned to the line, settled with the whole pool.
        _expect();
        emit Credited(1, 1, 110);
        _expect();
        emit Enrolled(1, 6);
        _expect();
        emit Settled(1, h, 110);
        arena.settle(1, h, ids1(1));

        // Cancel round 2: Normie 2 refunded, nothing to carry, cancelled.
        _expect();
        emit Credited(2, 2, 5);
        _expect();
        emit SponsorshipMoved(2, 3, 0);
        _expect();
        emit Cancelled(2, 5, 3);
        vm.prank(guardian);
        arena.cancel(2);

        // A delegate withdraws: `to` is the holder.
        _expect();
        emit Withdrawn(1, alice, 10);
        vm.prank(hot);
        store.withdraw(1, 10);

        // Skin bought by bob for Normie 1 with carol paying through an allowance: `buyer` is the caller.
        vm.prank(carol);
        ledger.approve(bob, 5);
        _expect();
        emit SkinPurchased(1, 1, bob, 5);
        vm.prank(bob);
        skins.purchase(1, 5, carol);

        // Burn and rescue.
        burnNormie(1);
        _expect();
        emit Rescued(1, treasury, 100);
        store.rescue(1, treasury);

        // Sponsorship released from a round that has not started.
        vm.prank(sponsorWallet);
        queue.sponsor(7, 9);
        _expect();
        emit SponsorshipReleased(7, carol, 9);
        arena.releaseSponsorship(7, carol, 9);
        assertBacked();
    }

    // ───────────── deploy script ─────────────

    /// @notice DeployArena.s.sol as written, then the steps its header lists, from ARENA_ADMIN. After the script the
    ///         broadcaster holds nothing; before step 1 no logic contract can write; after step 6 round 1 has run.
    function test_deployScript_thenTheDocumentedSteps() public {
        address admin = address(0xAD314);
        vm.setEnv("ARENA_PIXELS", vm.toString(address(ledger)));
        vm.setEnv("ARENA_COLLECTION", vm.toString(address(normies)));
        vm.setEnv("ARENA_ADAPTER", vm.toString(address(adapter)));
        vm.setEnv("ARENA_ADMIN", vm.toString(admin));
        vm.setEnv("ARENA_TREASURY", vm.toString(treasury));
        vm.setEnv("ARENA_DELEGATE_REGISTRY", vm.toString(address(regV2)));
        vm.setEnv("ARENA_DELEGATE_REGISTRY_V1", vm.toString(address(regV1)));
        DeployArena script = new DeployArena();
        (NormiesArenaStorage s, NormiesArena a, NormiesArenaQueue q, NormiesArenaSkins k) = script.run();

        // Ownership and wiring straight after the script.
        assertEq(s.owner(), admin);
        assertEq(a.owner(), admin);
        assertEq(q.owner(), admin);
        assertEq(k.owner(), admin);
        assertTrue(a.paused() && q.paused() && k.paused());
        assertEq(address(a.store()), address(s));
        assertEq(address(q.store()), address(s));
        assertEq(address(k.store()), address(s));
        assertEq(address(a.pixels()), address(ledger));
        assertEq(address(s.collection()), address(normies));
        assertEq(address(s.delegateRegistry()), address(regV2));
        assertEq(address(s.delegateRegistryV1()), address(regV1));
        assertEq(k.treasury(), treasury);
        assertFalse(
            s.authorizedWriters(address(a)) || s.authorizedWriters(address(q)) || s.authorizedWriters(address(k))
        );
        // The broadcaster (and this test, and the script) hold no role and no ownership.
        address[3] memory others = [tx.origin, address(this), address(script)];
        for (uint256 i; i < 3; ++i) {
            assertEq(s.rolesOf(others[i]) | a.rolesOf(others[i]) | q.rolesOf(others[i]) | k.rolesOf(others[i]), 0);
            assertFalse(s.authorizedWriters(others[i]));
        }

        // Steps 1 to 6 of the script header.
        vm.startPrank(admin);
        s.setAuthorizedWriter(address(a), true);
        s.setAuthorizedWriter(address(q), true);
        s.setAuthorizedWriter(address(k), true);
        vm.stopPrank();
        ledger.setMoverRoles(address(s), 4);
        ledger.setMoverRoles(address(q), 4);
        ledger.setMoverRoles(address(k), 4);
        assertEq(ledger.moverRoles(address(a)), 0);
        vm.startPrank(admin);
        q.grantRoles(sponsorWallet, 16);
        vm.stopPrank();
        vm.startPrank(sponsorWallet);
        q.sponsor(1, 100);
        q.sponsor(2, 100);
        vm.stopPrank();
        vm.startPrank(admin);
        a.grantRoles(operator, 8);
        a.grantRoles(guardian, 1);
        a.setPaused(false);
        q.setPaused(false);
        k.setPaused(false);
        vm.stopPrank();
        vm.startPrank(operator);
        a.startRound(1);
        a.finishRound(1);
        vm.stopPrank();
        assertTrue(s.roundOf(1).finished);
        assertEq(ledger.balanceOf(address(s)), s.totalAllocated() + s.totalPooled());
    }
}

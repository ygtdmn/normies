// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Vm } from "forge-std/src/Vm.sol";
import { ArenaTestBase } from "./ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";

/// @notice An indexer can rebuild every balance, state and round player count from the storage's events alone:
///         Leveled after each per-Normie change, RoundStarted for the implicit charges and drop-outs.
contract NormiesArenaEventsTest is ArenaTestBase {
    uint256 constant GIVEN = 16;
    uint256 constant IDS = 20; // ids 16..19 are never given: credits to them stay unregistered

    uint8 constant ACTIVE = 1;
    uint8 constant SHORT = 2;

    uint256[IDS] level;
    uint256[IDS] bal;
    uint8[IDS] state;

    /// forge-config: default.fuzz.runs = 64
    /// forge-config: ci.fuzz.runs = 256
    function testFuzzReplayFromEvents(uint256 seed) public {
        for (uint256 i; i < GIVEN; ++i) {
            give(i, [alice, bob, carol][i % 3]);
            vm.prank(identity.holders(i));
            queue.bindAgent(i, i);
        }
        vm.recordLogs();
        for (uint256 step; step < 120; ++step) {
            _act(uint256(keccak256(abi.encode(seed, step))));
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 leveled = NormiesArenaStorage.Leveled.selector;
        bytes32 started = NormiesArenaStorage.RoundStarted.selector;
        uint256 rounds;
        for (uint256 k; k < logs.length; ++k) {
            Vm.Log memory l = logs[k];
            if (l.emitter != address(store)) continue;
            if (l.topics[0] == leveled) {
                uint256 id = uint256(l.topics[1]);
                (uint256 b, uint256 lv, uint8 st) = abi.decode(l.data, (uint256, uint256, uint8));
                bal[id] = b;
                level[id] = lv;
                state[id] = st;
            } else if (l.topics[0] == started) {
                (uint256 price, bool free, uint256 players,, uint256 c,) =
                    abi.decode(l.data, (uint256, bool, uint256, uint256, uint256, uint256));
                uint256 counted;
                for (uint256 id; id < IDS; ++id) {
                    if (state[id] == ACTIVE && !free) {
                        if (level[id] >= c) {
                            bal[id] = level[id] - c;
                        } else {
                            state[id] = SHORT;
                            bal[id] = level[id] - (c - price);
                        }
                    }
                    if (free ? state[id] == ACTIVE || state[id] == SHORT : state[id] == ACTIVE) ++counted;
                }
                assertEq(counted, players, "players from events");
                ++rounds;
            }
        }
        assertGt(rounds, 0);
        for (uint256 id; id < IDS; ++id) {
            assertEq(bal[id], store.balanceOf(id), "balance from events");
            assertEq(state[id], store.stateOf(id), "state from events");
        }
    }

    /// @dev One random action.
    function _act(uint256 rnd) internal {
        uint256 kind = rnd % 10;
        uint256 id = (rnd >> 8) % GIVEN;
        bool burned = identity.holders(id) == address(0);
        if (kind <= 3) {
            if (!burned) _wallet(kind, id, 1 + (rnd >> 16) % 30);
        } else if (kind <= 6) {
            _round(kind, rnd);
        } else if (kind == 7) {
            if (!burned && (rnd >> 24) % 5 == 0) identity.burn(id);
        } else if (kind == 8) {
            if (burned && store.stateOf(id) != 3) store.clear(id);
        } else if (burned && store.balanceOf(id) != 0) {
            store.rescue(id, treasury);
        }
    }

    /// @dev Join, top up or withdraw for a live Normie.
    function _wallet(uint256 kind, uint256 id, uint256 amount) internal {
        if (kind == 0) {
            if (store.isRegistered(id)) return;
            vm.prank(identity.holders(id));
            queue.join(id);
        } else if (kind <= 2) {
            topUp(id, amount);
        } else {
            uint256 b = store.balanceOf(id);
            if (b == 0) return;
            vm.prank(identity.holders(id));
            store.withdraw(id, 1 + amount % b);
        }
    }

    /// @dev Start, pay out, end or cancel.
    function _round(uint256 kind, uint256 rnd) internal {
        uint256 current = store.currentRound();
        bool open = current != 0 && store.isOpen(current);
        if (kind == 4) {
            if (!open) next((rnd >> 24) % 3 == 0 ? 0 : 1 + (rnd >> 32) % 12);
        } else if (kind == 5) {
            if (open) _payout(current, rnd);
        } else if (open) {
            if ((rnd >> 24) % 4 == 0) arena.cancel(current);
            else arena.endRound(current, none, none, none);
        }
    }

    /// @dev A refund (when the pool allows) and a prize of random size.
    function _payout(uint256 current, uint256 rnd) internal {
        uint256 budget = store.roundOf(current).unpaid;
        uint256 price = store.roundOf(current).price;
        uint256[] memory refundees = budget >= price ? ids1((rnd >> 40) % IDS) : none;
        uint256 left = budget - refundees.length * price;
        uint256[] memory amounts = ids1(left == 0 ? 0 : (rnd >> 48) % (left + 1));
        arena.payout(current, ids1((rnd >> 56) % IDS), amounts, refundees);
    }
}

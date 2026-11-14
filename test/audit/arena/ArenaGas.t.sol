// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Vm } from "forge-std/src/Vm.sol";
import { ArenaAuditBase } from "./ArenaAuditBase.sol";
import { NormiesArenaStorage } from "../../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../../../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../../../src/NormiesArenaSkins.sol";

/**
 * @notice D8: worst-case gas at the sizes the contracts enforce on chain, against the 16,777,216 per-transaction cap.
 *
 *         RUN WITH --isolate. In isolation mode every top-level call below is its own transaction: storage starts
 *         cold, each slot's "original value" is its value before that transaction (so a write to a slot changed
 *         earlier in the test is charged in full), and the 21,000 base plus calldata are charged. Calibration
 *         (ArenaGasCalib.t.sol): a call made with {gas: g} runs as a transaction with gas limit g + 21,000.
 *
 *         Each scenario (a) must succeed with a gas limit of exactly the cap, and (b) reports the smallest gas
 *         limit at which it succeeds, found by binary search. (b) is the number to compare with the cap: the cap
 *         is on the limit, before refunds.
 */
contract ArenaGasTest is ArenaAuditBase {
    uint256 constant BASE = 21_000;

    function _measure(string memory name, address caller, address target, bytes memory data) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(caller);
        (bool ok,) = target.call{ gas: GAS_CAP - BASE }(data);
        assertTrue(ok, "must succeed with a gas limit equal to the cap");
        Vm.Gas memory g = vm.lastCallGas();
        vm.revertToState(snap);
        uint256 lo = 1;
        uint256 hi = GAS_CAP - BASE;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            snap = vm.snapshotState();
            vm.prank(caller);
            (ok,) = target.call{ gas: mid }(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        uint256 minLimit = lo + BASE;
        emit log_string(name);
        emit log_named_uint("  tx gas used (after refund)", g.gasTotalUsed);
        emit log_named_int("  refund", g.gasRefunded);
        emit log_named_uint("  MIN TX GAS LIMIT", minLimit);
        emit log_named_uint("  headroom under 16,777,216", GAS_CAP - minLimit);
        assertLt(minLimit, GAS_CAP);
    }

    // ───────────── settle / cancel at MAX_CAPACITY, every Normie short and returning to the line ─────────────

    /// @dev Round 1: paid, 300 players (ids 9700..9999, distinct holders, balance exactly the price), finished with
    ///      results posted, pool 300 + 77. Round 2 (paid) then takes every one of them out of the line short of funds.
    function _fullRoundAllShort() internal returns (uint256[] memory winners, bytes32 h) {
        assertEq(arena.MAX_CAPACITY(), 300);
        arena.setCapacity(300);
        arena.setWinnerBps(10_000);
        arena.setMaxScan(80);
        arena.setFreeRound(1, false);
        arena.setFreeRound(2, false);
        vm.prank(sponsorWallet);
        queue.sponsor(1, 77);
        for (uint256 i; i < 300; ++i) {
            address holder = address(uint160(0x100000 + i));
            ledger.mintTo(holder, 1);
            join(9700 + i, holder, 1);
        }
        admitAll(1);
        assertEq(store.playerCount(1), 300);
        arena.finishRound(1);
        h = keccak256("r");
        arena.postResults(1, h);
        admitAll(2);
        assertEq(store.playerCount(2), 0);
        for (uint256 i; i < 300; ++i) {
            assertTrue(shortOfFunds(9700 + i));
            assertEq(store.balanceOf(9700 + i), 0);
        }
        winners = arena.players(1);
        assertEq(arena.winnerCountOf(1), 300);
    }

    function test_gas_settle_300_winners_all_returning() public {
        (uint256[] memory winners, bytes32 h) = _fullRoundAllShort();
        _measure(
            "settle: 300 winners, all short, all returning to the line",
            address(this),
            address(arena),
            abi.encodeCall(arena.settle, (1, h, winners))
        );
        arena.settle(1, h, winners);
        for (uint256 i; i < 300; ++i) {
            assertTrue(inLine(9700 + i));
        }
        assertBacked();
    }

    function test_gas_cancel_300_players_all_returning() public {
        _fullRoundAllShort();
        _measure(
            "cancel: 300 players, all short, all returning to the line",
            guardian,
            address(arena),
            abi.encodeCall(arena.cancel, (1))
        );
        arena.cancel(1);
        for (uint256 i; i < 300; ++i) {
            assertTrue(inLine(9700 + i));
            assertEq(store.balanceOf(9700 + i), 1);
        }
        assertBacked();
    }

    // ───────────── admit at MAX_SCAN ─────────────

    function _line80(uint256 balance) internal {
        assertEq(arena.MAX_SCAN(), 80);
        arena.setCapacity(300);
        arena.setMaxScan(80);
        arena.setFreeRound(1, false);
        for (uint256 i; i < 80; ++i) {
            address holder = address(uint160(0x100000 + i));
            ledger.mintTo(holder, balance);
            join(9900 + i, holder, balance);
        }
    }

    function test_gas_admit_80_all_seated_paid() public {
        _line80(2);
        vm.prank(operator);
        arena.startRound(1);
        _measure(
            "admit(80): all seated in a paid round", operator, address(arena), abi.encodeCall(arena.admit, (1, 80))
        );
        vm.prank(operator);
        arena.admit(1, 80);
        assertEq(store.playerCount(1), 80);
    }

    function test_gas_admit_80_all_short() public {
        _line80(2);
        arena.setEntryPrice(5);
        vm.prank(operator);
        arena.startRound(1);
        _measure("admit(80): all short of funds", operator, address(arena), abi.encodeCall(arena.admit, (1, 80)));
    }

    function test_gas_admit_80_all_burned() public {
        _line80(2);
        for (uint256 i; i < 80; ++i) {
            burnNormie(9900 + i);
        }
        vm.prank(operator);
        arena.startRound(1);
        _measure("admit(80): all burned", operator, address(arena), abi.encodeCall(arena.admit, (1, 80)));
    }

    function test_gas_admit_80_all_stale() public {
        _line80(2);
        // Every holder pauses and resumes, leaving 80 stale tickets at the head.
        for (uint256 i; i < 80; ++i) {
            address holder = address(uint160(0x100000 + i));
            vm.startPrank(holder);
            queue.pause(9900 + i);
            queue.resume(9900 + i);
            vm.stopPrank();
        }
        vm.prank(operator);
        arena.startRound(1);
        _measure("admit(80): all stale tickets", operator, address(arena), abi.encodeCall(arena.admit, (1, 80)));
        vm.prank(operator);
        arena.admit(1, 80);
        assertEq(store.playerCount(1), 0);
    }

    // ───────────── Queue batches at MAX_BATCH ─────────────

    /// @dev 50 fresh Normies, each with its own holder who gave `hot` a v1 wallet-level delegation (the costliest
    ///      path through holderFor: three v2 reads miss, then v1 falls through token and contract to wallet level).
    function _fifty(bool link) internal returns (uint256[] memory ids, uint256[] memory amounts) {
        assertEq(queue.MAX_BATCH(), 50);
        ids = new uint256[](50);
        amounts = new uint256[](50);
        for (uint256 i; i < 50; ++i) {
            address holder = address(uint160(0x200000 + i));
            ids[i] = 9900 + i;
            amounts[i] = 3;
            give(ids[i], holder);
            if (link) {
                vm.prank(holder);
                queue.bindAgent(ids[i], ids[i]);
            }
            regV1.delegateForAll(hot, holder, true);
        }
    }

    function test_gas_depositRegisteredBatch_50_by_delegate() public {
        (uint256[] memory ids, uint256[] memory amounts) = _fifty(false);
        _measure(
            "depositRegisteredBatch(50): v1 wallet-level delegate, 50 distinct holders, first link + first deposit",
            hot,
            address(queue),
            abi.encodeCall(queue.depositRegisteredBatch, (ids, amounts, ids))
        );
    }

    function test_gas_depositBatch_50_enroll_by_delegate() public {
        (uint256[] memory ids, uint256[] memory amounts) = _fifty(true);
        _measure(
            "depositBatch(50, enroll): v1 wallet-level delegate, 50 distinct holders",
            hot,
            address(queue),
            abi.encodeCall(queue.depositBatch, (ids, amounts, true))
        );
    }

    function test_gas_resumeBatch_50_by_delegate() public {
        (uint256[] memory ids,) = _fifty(true);
        _measure("resumeBatch(50)", hot, address(queue), abi.encodeCall(queue.resumeBatch, (ids)));
    }

    function test_gas_resumeRegisteredBatch_50_by_delegate() public {
        (uint256[] memory ids,) = _fifty(false);
        _measure(
            "resumeRegisteredBatch(50)", hot, address(queue), abi.encodeCall(queue.resumeRegisteredBatch, (ids, ids))
        );
    }

    function test_gas_pauseBatch_50_by_delegate() public {
        (uint256[] memory ids, uint256[] memory amounts) = _fifty(true);
        vm.prank(hot);
        queue.depositBatch(ids, amounts, true);
        _measure("pauseBatch(50)", hot, address(queue), abi.encodeCall(queue.pauseBatch, (ids)));
    }

    // ───────────── withdrawBatch at MAX_WITHDRAW_BATCH ─────────────

    /// @dev 100 Normies with 100 distinct holders whose ledger wallets have never held a pixel (the delegate paid the
    ///      top-ups), so each payout writes three fresh ledger slots (balance, locked amount, unlock time).
    function test_gas_withdrawBatch_100_by_delegate_fresh_holders() public {
        assertEq(store.MAX_WITHDRAW_BATCH(), 100);
        uint256[] memory ids = new uint256[](100);
        uint256[] memory amounts = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            address holder = address(uint160(0x300000 + i));
            ids[i] = 9900 + i;
            amounts[i] = 3;
            give(ids[i], holder);
            regV1.delegateForAll(hot, holder, true);
            vm.prank(hot);
            queue.deposit(ids[i], 3, false);
            assertEq(ledger.balanceOf(holder), 0);
        }
        _measure(
            "withdrawBatch(100): v1 wallet-level delegate, 100 distinct fresh holders, real ledger",
            hot,
            address(store),
            abi.encodeCall(store.withdrawBatch, (ids, amounts))
        );
        vm.prank(hot);
        store.withdrawBatch(ids, amounts);
        assertEq(ledger.balanceOf(address(uint160(0x300000))), 3);
        assertBacked();
    }

    // ───────────── deployments ─────────────

    /// @dev Under --isolate each `new` is its own creation transaction; the gasleft difference is its gas.
    function test_gas_deployments() public {
        uint256 g = gasleft();
        NormiesArenaStorage s = new NormiesArenaStorage(
            address(ledger), address(normies), address(adapter), address(regV2), address(regV1), address(this)
        );
        emit log_named_uint("deploy NormiesArenaStorage", g - gasleft());
        assertLt(g - gasleft(), GAS_CAP);
        g = gasleft();
        new NormiesArena(address(s), address(this));
        emit log_named_uint("deploy NormiesArena", g - gasleft());
        assertLt(g - gasleft(), GAS_CAP);
        g = gasleft();
        new NormiesArenaQueue(address(s), address(this));
        emit log_named_uint("deploy NormiesArenaQueue", g - gasleft());
        g = gasleft();
        new NormiesArenaSkins(address(s), address(this), treasury);
        emit log_named_uint("deploy NormiesArenaSkins", g - gasleft());
    }
}

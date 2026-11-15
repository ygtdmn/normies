// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Vm } from "forge-std/src/Vm.sol";
import { ArenaTestBase } from "../../arena/ArenaTestBase.sol";

/**
 * @notice Worst-case gas at the sizes the contracts enforce on chain, against the 16,777,216 per-transaction cap.
 *
 *         RUN WITH --isolate. In isolation mode every top-level call below is its own transaction: storage starts
 *         cold, each slot's "original value" is its value before that transaction, and the 21,000 base plus
 *         calldata are charged. A call made with {gas: g} runs as a transaction with gas limit g + 21,000.
 *
 *         Each scenario (a) must succeed with a gas limit of exactly the cap, and (b) reports the smallest gas
 *         limit at which it succeeds, found by binary search. (b) is the number to compare with the cap.
 *
 *         These use the mock ledger; the real ledger's costs for deposit and withdraw batches are measured in
 *         NormiesArenaLedger.t.sol.
 */
contract ArenaGasTest is ArenaTestBase {
    uint256 constant BASE = 21_000;
    uint256 constant GAS_CAP = 16_777_216;

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
        emit log_named_uint("  MIN TX GAS LIMIT", minLimit);
        emit log_named_uint("  headroom under 16,777,216", GAS_CAP - minLimit);
        assertLt(minLimit, GAS_CAP);
    }

    /// @dev Registers Normie `id` for alice with `amount` pixels, linking its agent directly on the storage.
    function _quickJoin(uint256 id, uint256 amount) internal {
        if (ledger.balanceOf(alice) < amount) ledger.mint(alice, amount);
        identity.setOwner(id, alice);
        identity.bind(id, id);
        vm.prank(address(queue));
        store.linkAgent(id, id);
        vm.prank(alice);
        if (amount == 0) queue.join(id);
        else queue.deposit(id, amount);
    }

    /// @dev Registers Normie `id` with `amount` pixels straight through the writer (the pixels are minted to the
    ///      storage beforehand), to seed thousands of Normies within the test's gas budget.
    function _rawJoin(uint256 id, uint256 amount) internal {
        vm.prank(address(queue));
        if (amount == 0) store.register(id);
        else store.deposit(id, alice, amount, true);
    }

    /// @dev Runs `count` empty paid rounds at price 1.
    function _emptyRounds(uint256 count) internal {
        for (uint256 i; i < count; ++i) {
            next(1);
        }
    }

    /// @notice startRound at the highest price, with C misaligned (1 mod 16) and every one of the 10,000 lanes it
    ///         reads holding a Normie: 626 cold slots.
    function testGasStartRoundAtMaxPrice() public {
        next(0);
        next(0);
        next(1); // C = 1
        ledger.mint(address(store), 49_995_000); // sum of 0 .. 9,999
        for (uint256 i; i < 10_000; ++i) {
            _rawJoin(i, i); // levels 1 .. 10,000
        }
        endOpen();
        arena.setEntryPrice(10_000);
        assertEq(arena.previewPlayers(), 0); // balances 0 .. 9,999: all of them drop
        _measure(
            "startRound, price 10,000, 626 full lane slots",
            operator,
            address(arena),
            abi.encodeCall(arena.startRound, (4))
        );
        arena.startRound(4);
        assertEq(store.roundOf(4).players, 0);
        assertEq(store.activeCount(), 0);
    }

    /// @notice A full endRound: 300 prizes to short Normies that each dropped out in a different round over 520
    ///         rounds (distinct leftover searches), each prize landing in a fresh lane slot.
    function testGasEndRoundAt300Entries() public {
        uint256 n = arena.MAX_PAYOUT_ENTRIES();
        for (uint256 i; i < n; ++i) {
            _quickJoin(i, i + 1); // drops at round 4 + i
        }
        next(0);
        next(0);
        _emptyRounds(520);
        assertEq(store.activeCount(), 0);
        endOpen();
        ledger.mint(sponsorWallet, 1_000_000);
        uint256 upcoming = store.currentRound() + 1;
        vm.prank(sponsorWallet);
        queue.sponsor(upcoming, 900_000);
        uint256 round = next(1);
        uint256[] memory winners = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            winners[i] = i;
            amounts[i] = 100 + i * 17;
        }
        _measure(
            "endRound, 300 prizes to short Normies with distinct drop rounds over 520 rounds",
            operator,
            address(arena),
            abi.encodeCall(arena.endRound, (round, winners, amounts, none))
        );
        _measure(
            "payout, 300 prizes to short Normies with distinct drop rounds over 520 rounds",
            operator,
            address(arena),
            abi.encodeCall(arena.payout, (round, winners, amounts, none))
        );
    }

    /// @notice 300 refunds in a paid round to cold active players.
    function testGasEndRoundAt300Refunds() public {
        uint256 n = arena.MAX_PAYOUT_ENTRIES();
        for (uint256 i; i < n; ++i) {
            _quickJoin(i, 1000 + i * 16);
        }
        next(0);
        next(0);
        uint256 round = next(3);
        uint256[] memory refundees = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            refundees[i] = i;
        }
        _measure(
            "endRound, 300 refunds to cold active players",
            operator,
            address(arena),
            abi.encodeCall(arena.endRound, (round, none, none, refundees))
        );
    }

    /// @dev Seeds `n` Normies for the batch scenarios: even ids short (each dropping out in a different round,
    ///      leftover 1), odd ids active with large balances in distinct lane slots. Then 520 rounds at price 2.
    function _mixedNormies(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            _quickJoin(i, i % 2 == 0 ? 2 * i + 3 : 5000 + i * 16);
            ids[i] = i;
        }
        next(0);
        next(0);
        for (uint256 i; i < 520; ++i) {
            next(2);
        }
        assertEq(store.stateOf(0), 2);
        assertEq(store.stateOf(1), 1);
    }

    /// @notice clearBatch at MAX_BATCH: burned Normies, half short with distinct drop rounds, half active.
    function testGasClearBatch() public {
        uint256[] memory ids = _mixedNormies(store.MAX_BATCH());
        for (uint256 i; i < ids.length; ++i) {
            identity.burn(i);
        }
        _measure(
            "clearBatch, 100 burned Normies (half lazily short)",
            bob,
            address(store),
            abi.encodeCall(store.clearBatch, (ids))
        );
    }

    /// @notice withdrawBatch at MAX_BATCH (mock ledger): half short with distinct drop rounds, half active moving to
    ///         fresh lane slots.
    function testGasWithdrawBatch() public {
        uint256[] memory ids = _mixedNormies(store.MAX_BATCH());
        uint256[] memory amounts = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            amounts[i] = i % 2 == 0 ? 1 : 2000;
        }
        _measure(
            "withdrawBatch, 100 entries, half lazily short (mock ledger)",
            alice,
            address(store),
            abi.encodeCall(store.withdrawBatch, (ids, amounts))
        );
    }

    /// @notice A single top-up bringing a short Normie back after 520 rounds.
    function testGasDepositAfterLongShort() public {
        _quickJoin(1, 1);
        next(0);
        next(0);
        next(2);
        _emptyRounds(520);
        _measure(
            "deposit, short Normie back after 520 rounds (mock ledger)",
            alice,
            address(queue),
            abi.encodeCall(queue.deposit, (1, 5))
        );
    }
}

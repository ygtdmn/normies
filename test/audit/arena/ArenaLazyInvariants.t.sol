// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { ArenaTestBase, ArenaLedgerMock, ArenaIdentityMock } from "../../arena/ArenaTestBase.sol";
import { NormiesArenaStorage } from "../../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../../../src/NormiesArena.sol";

/// @notice Drives the Arena at random and keeps a plain model alongside: explicit balances, an explicit charge loop
///         at every round start, explicit short and player flags.
contract ArenaLazyHandler is Test {
    uint256 public constant N = 16;
    /// @dev Ids N and N + 1 are never given to anyone: credits to them stay unregistered.
    uint256 public constant IDS = N + 2;

    NormiesArenaStorage public store;
    NormiesArenaQueue public queue;
    NormiesArena public arena;
    ArenaLedgerMock public ledger;
    ArenaIdentityMock public identity;
    address public owner;
    address public sponsorWallet;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA201)];

    uint256[IDS] public bal;
    bool[IDS] public registered;
    bool[IDS] public cleared;
    bool[IDS] public short_;
    bool[IDS] public player;
    bool[IDS] public burned;
    uint256 public players;
    uint256 public calls;

    constructor(
        NormiesArenaStorage store_,
        NormiesArenaQueue queue_,
        NormiesArena arena_,
        ArenaLedgerMock ledger_,
        ArenaIdentityMock identity_,
        address sponsorWallet_
    ) {
        store = store_;
        queue = queue_;
        arena = arena_;
        ledger = ledger_;
        identity = identity_;
        owner = address(this); // the test hands ownership of the Arena contracts to the handler
        sponsorWallet = sponsorWallet_;
        for (uint256 i; i < N; ++i) {
            identity.setOwner(i, actors[i % 3]);
            identity.bind(i, i);
        }
        for (uint256 i; i < 3; ++i) {
            ledger.mint(actors[i], 10_000_000);
        }
    }

    function _link(uint256 id) internal {
        if (!store.agentBound(id)) {
            vm.prank(identity.holders(id));
            queue.bindAgent(id, id);
        }
    }

    function join(uint256 seed) external {
        uint256 id = seed % N;
        if (registered[id] || burned[id]) return;
        _link(id);
        vm.prank(identity.holders(id));
        queue.join(id);
        registered[id] = true;
        short_[id] = false;
        ++calls;
    }

    function deposit(uint256 seed, uint256 amount) external {
        uint256 id = seed % N;
        if (burned[id]) return;
        amount = 1 + amount % 40;
        _link(id);
        vm.prank(identity.holders(id));
        queue.deposit(id, amount);
        bal[id] += amount;
        registered[id] = true;
        short_[id] = false;
        ++calls;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        uint256 id = seed % N;
        if (burned[id] || bal[id] == 0) return;
        amount = 1 + amount % bal[id];
        vm.prank(identity.holders(id));
        store.withdraw(id, amount);
        bal[id] -= amount;
        ++calls;
    }

    function transfer(uint256 seed, uint256 to) external {
        uint256 id = seed % N;
        if (burned[id]) return;
        identity.setOwner(id, actors[to % 3]);
    }

    function startRound(uint256 seed) external {
        uint256 current = store.currentRound();
        if (current != 0 && store.isOpen(current)) return;
        uint256 round = current + 1;
        bool free = seed % 4 == 0;
        uint256 price = free ? 0 : 1 + (seed >> 8) % 30;
        if ((seed >> 40) % 16 == 0) price = 10_000 - (seed >> 48) % 10;
        vm.startPrank(owner);
        if (arena.freeRound(round) != free) arena.setFreeRound(round, free);
        if (!free) arena.setEntryPrice(price);
        vm.stopPrank();
        if (free && store.poolOf(round) == 0) {
            vm.prank(sponsorWallet);
            queue.sponsor(round, 1 + (seed >> 16) % 50);
        }
        vm.prank(owner);
        arena.startRound(round);
        players = 0;
        for (uint256 i; i < IDS; ++i) {
            if (!registered[i]) {
                player[i] = false;
            } else if (free) {
                player[i] = true;
            } else if (!short_[i] && bal[i] >= price) {
                bal[i] -= price;
                player[i] = true;
            } else {
                short_[i] = true;
                player[i] = false;
            }
            if (player[i]) ++players;
        }
        ++calls;
    }

    function payout(uint256 seed, bool end) external {
        uint256 round = store.currentRound();
        if (round == 0 || !store.isOpen(round)) return;
        uint256 price = store.roundOf(round).price;
        uint256 budget = store.roundOf(round).unpaid;
        uint256 nRefund = seed % 4;
        if (nRefund * price > budget) nRefund = 0;
        budget -= nRefund * price;
        uint256[] memory refundees = new uint256[](nRefund);
        for (uint256 i; i < nRefund; ++i) {
            refundees[i] = uint256(keccak256(abi.encode(seed, "r", i))) % IDS;
        }
        uint256 nWin = (seed >> 8) % 4;
        uint256[] memory winners = new uint256[](nWin);
        uint256[] memory amounts = new uint256[](nWin);
        for (uint256 i; i < nWin; ++i) {
            winners[i] = uint256(keccak256(abi.encode(seed, "w", i))) % IDS;
            uint256 a = budget == 0 ? 0 : uint256(keccak256(abi.encode(seed, "a", i))) % (budget + 1);
            amounts[i] = a;
            budget -= a;
        }
        vm.startPrank(owner);
        if (end) arena.endRound(round, winners, amounts, refundees);
        else if (nRefund + nWin > 0) arena.payout(round, winners, amounts, refundees);
        vm.stopPrank();
        if (!end && nRefund + nWin == 0) return;
        if (price != 0) {
            for (uint256 i; i < nRefund; ++i) {
                _credit(refundees[i], price);
            }
        }
        for (uint256 i; i < nWin; ++i) {
            if (amounts[i] != 0) _credit(winners[i], amounts[i]);
        }
        ++calls;
    }

    function cancel() external {
        uint256 round = store.currentRound();
        if (round == 0 || !store.isOpen(round)) return;
        vm.prank(owner);
        arena.cancel(round);
        ++calls;
    }

    function burn(uint256 seed) external {
        uint256 id = seed % N;
        if (burned[id]) return;
        identity.burn(id);
        burned[id] = true;
    }

    function clear(uint256 seed) external {
        uint256 id = seed % N;
        if (!burned[id] || cleared[id]) return;
        store.clear(id);
        _clear(id);
        ++calls;
    }

    function rescue(uint256 seed) external {
        uint256 id = seed % N;
        if (!burned[id] || bal[id] == 0) return;
        vm.prank(owner);
        store.rescue(id, owner);
        _clear(id);
        bal[id] = 0;
        ++calls;
    }

    function _credit(uint256 id, uint256 amount) internal {
        bal[id] += amount;
        if (registered[id]) short_[id] = false;
    }

    function _clear(uint256 id) internal {
        registered[id] = false;
        short_[id] = false;
        cleared[id] = true;
    }
}

contract ArenaLazyInvariantsTest is ArenaTestBase {
    ArenaLazyHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new ArenaLazyHandler(store, queue, arena, ledger, identity, sponsorWallet);
        arena.transferOwnership(address(handler));
        store.transferOwnership(address(handler));
        queue.transferOwnership(address(handler));
        targetContract(address(handler));
    }

    /// @dev Every Normie's balance, state and player flag match the model.
    function invariant_matchesModel() public view {
        uint256 total;
        uint256 reg;
        uint256 active;
        for (uint256 i; i < handler.IDS(); ++i) {
            assertEq(store.balanceOf(i), handler.bal(i), "balance");
            uint8 state = handler.cleared(i) ? 3 : !handler.registered(i) ? 0 : handler.short_(i) ? 2 : 1;
            assertEq(store.stateOf(i), state, "state");
            if (store.currentRound() != 0) assertEq(store.isPlayer(i), handler.player(i), "player");
            total += handler.bal(i);
            if (handler.registered(i)) ++reg;
            if (state == 1) ++active;
        }
        assertEq(store.totalAllocated(), total, "totalAllocated");
        assertEq(store.registeredCount(), reg, "registeredCount");
        assertEq(store.activeCount(), active, "activeCount");
    }

    /// @dev Custody: the ledger holds exactly every balance plus every unpaid pool, and the pools add up.
    function invariant_custody() public view {
        assertEq(ledger.balanceOf(address(store)), uint256(store.totalAllocated()) + store.totalPooled(), "backing");
        uint256 current = store.currentRound();
        uint256 pooled;
        uint256 last = current + 1 < 2 ? 2 : current + 1;
        for (uint256 r = 1; r <= last; ++r) {
            NormiesArenaStorage.Round memory g = store.roundOf(r);
            pooled += g.unpaid;
            if (g.ended || g.cancelled) assertEq(g.unpaid, 0, "closed round unpaid");
        }
        assertEq(store.totalPooled(), pooled, "totalPooled");
    }

    /// @dev The open round charged exactly players * price and counted the model's players.
    function invariant_roundAccounting() public view {
        uint256 current = store.currentRound();
        if (current == 0) return;
        NormiesArenaStorage.Round memory g = store.roundOf(current);
        assertEq(g.players, handler.players(), "players");
        assertEq(g.fees, uint256(g.players) * g.price, "fees");
        assertEq(g.cumulative, store.cumulative(), "cumulative");
        if (current > 1) assertGe(g.cumulative, store.roundOf(current - 1).cumulative, "C never decreases");
    }

    function afterInvariant() external view {
        assertGt(handler.calls(), 0);
    }
}

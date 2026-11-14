// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { NormiesArenaStorage } from "../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../../src/NormiesArenaSkins.sol";
import { MockDelegateRegistryV1, MockDelegateRegistryV2 } from "../mocks/MockDelegateRegistries.sol";

/// @notice Pixel ledger stand-in: wallet balances, allowances, and moves by authorized movers only.
contract ArenaLedgerMock {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public movers;

    function mint(address who, uint256 amount) external {
        balanceOf[who] += amount;
    }

    function authorize(address who) external {
        movers[who] = true;
    }

    function revoke(address who) external {
        movers[who] = false;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function moveBalance(address from, address to, uint256 amount) external {
        require(movers[msg.sender], "not a mover");
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function useAllowance(address owner, address spender, uint256 amount) external {
        require(movers[msg.sender], "not a mover");
        if (owner == spender) return;
        require(allowance[owner][spender] >= amount, "allowance");
        allowance[owner][spender] -= amount;
    }
}

/// @notice The Normies collection and the ERC-8004 adapter in one: holders, burns, transfers and agent bindings.
contract ArenaIdentityMock {
    mapping(uint256 => address) public holders;
    /// @dev agentId => token id + 1; zero means the agent has no binding.
    mapping(uint256 => uint256) public bindings;

    function setOwner(uint256 id, address who) external {
        holders[id] = who;
    }

    function burn(uint256 id) external {
        delete holders[id];
    }

    function bind(uint256 agentId, uint256 id) external {
        bindings[agentId] = id + 1;
    }

    function unbind(uint256 agentId) external {
        delete bindings[agentId];
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(holders[id] != address(0), "no token");
        return holders[id];
    }

    function bindingOf(uint256 agentId) external view returns (uint8, address, uint256) {
        require(bindings[agentId] != 0, "no binding");
        return (0, address(this), bindings[agentId] - 1);
    }
}

/// @notice A deployed and wired Arena: rounds 1 and 2 free and sponsored with 100 each, all unpaused.
abstract contract ArenaTestBase is Test {
    ArenaLedgerMock ledger;
    ArenaIdentityMock identity;
    MockDelegateRegistryV2 registry;
    MockDelegateRegistryV1 registryV1;
    NormiesArenaStorage store;
    NormiesArenaQueue queue;
    NormiesArena arena;
    NormiesArenaSkins skins;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address hot = address(0x407);
    address operator = address(0x0BE);
    address guardian = address(0x6A2D);
    address sponsorWallet = address(0x5B0);
    address treasury = address(0x7EA);

    function setUp() public virtual {
        ledger = new ArenaLedgerMock();
        identity = new ArenaIdentityMock();
        registry = new MockDelegateRegistryV2();
        registryV1 = new MockDelegateRegistryV1();
        store = new NormiesArenaStorage(
            address(ledger), address(identity), address(identity), address(registry), address(registryV1), address(this)
        );
        arena = new NormiesArena(address(store), address(this));
        queue = new NormiesArenaQueue(address(store), address(this));
        skins = new NormiesArenaSkins(address(store), address(this), treasury);
        store.setAuthorizedWriter(address(arena), true);
        store.setAuthorizedWriter(address(queue), true);
        store.setAuthorizedWriter(address(skins), true);
        ledger.authorize(address(store));
        ledger.authorize(address(queue));
        ledger.authorize(address(skins));
        arena.grantRoles(operator, arena.OPERATOR_ROLE());
        arena.grantRoles(guardian, 1);
        queue.grantRoles(sponsorWallet, queue.SPONSOR_ROLE());
        for (uint256 i; i < 5; ++i) {
            ledger.mint([alice, bob, carol, hot, sponsorWallet][i], 100_000);
        }
        vm.startPrank(sponsorWallet);
        queue.sponsor(1, 100);
        queue.sponsor(2, 100);
        vm.stopPrank();
        arena.setPaused(false);
        queue.setPaused(false);
        skins.setPaused(false);
    }

    /// @dev Gives Normie `id` to `who` and binds agent `id` to it on the adapter (not yet linked in the Arena).
    function give(uint256 id, address who) internal {
        identity.setOwner(id, who);
        identity.bind(id, id);
    }

    /// @dev Gives Normie `id` to `who`, links its agent and joins the line with `amount` pixels.
    function join(uint256 id, address who, uint256 amount) internal {
        give(id, who);
        vm.prank(who);
        queue.bindAgent(id, id);
        vm.prank(who);
        queue.deposit(id, amount, true);
    }

    /// @dev Finishes whatever round is open, then starts each round up to `round`.
    function openRound(uint256 round) internal {
        uint256 current = store.currentRound();
        if (current == round && store.isOpen(round)) return;
        while (current < round) {
            if (store.isOpen(current)) arena.finishRound(current);
            arena.startRound(++current);
        }
        assertTrue(store.isOpen(round));
    }

    /// @dev Opens `round` and admits until its admissions close.
    function admitAll(uint256 round) internal {
        openRound(round);
        for (uint256 i; i < 40 && !store.roundOf(round).closed; ++i) {
            arena.admit(round, arena.maxScan());
        }
        assertTrue(store.roundOf(round).closed);
    }

    /// @dev Finishes `round`, posts a result and settles it for `winners`.
    function finishAndSettle(uint256 round, uint256[] memory winners) internal {
        if (store.isOpen(round)) arena.finishRound(round);
        bytes32 result = keccak256(abi.encode("result", round));
        arena.postResults(round, result);
        arena.settle(round, result, winners);
    }

    function ids1(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function inLine(uint256 id) internal view returns (bool active) {
        (, active,) = store.enrollment(id);
    }

    function ticketOf(uint256 id) internal view returns (uint64 ticket) {
        (ticket,,) = store.enrollment(id);
    }

    function shortOfFunds(uint256 id) internal view returns (bool needsFunds) {
        (,, needsFunds) = store.enrollment(id);
    }

    /// @dev Custody invariant: the storage's ledger balance equals balances plus unpaid pools (no surplus here).
    function assertBacked() internal view {
        assertEq(ledger.balanceOf(address(store)), store.totalAllocated() + store.totalPooled());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { NormiesCanvasStorageV2 } from "../../src/NormiesCanvasStorageV2.sol";
import { NormiesArenaStorage, IArenaCollection, IArenaAdapter } from "../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../../src/NormiesArenaSkins.sol";

interface IForkAdapterRegistration {
    function register(uint8 standard, address collection, uint256 id, string calldata uri) external returns (uint256);
}

/// @notice Opt-in mainnet rehearsal against the real ledger, collection, adapter and delegate.xyz registries. Set
///         ARENA_FORK_RPC_URL and ARENA_FORK_NORMIE_ID (and optionally ARENA_FORK_AGENT_ID); skipped otherwise.
contract NormiesArenaForkTest is Test {
    address constant COLLECTION = 0x9Eb6E2025B64f340691e424b7fe7022fFDE12438;
    address constant ADAPTER = 0xde152AfB7db5373F34876E1499fbD893A82dD336;
    address constant MINTER = 0xF14f2852e1fD6A4108156054AF49B3915dc40E2e;

    function testMainnetRoundsSaleAndWithdraw() public {
        string memory url = vm.envOr("ARENA_FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, 1);
        uint256 id = vm.envUint("ARENA_FORK_NORMIE_ID");
        uint256 agentId = vm.envOr("ARENA_FORK_AGENT_ID", uint256(0));
        NormiesCanvasStorageV2 pixels = NormiesCanvasStorageV2(0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084);
        address holder = IArenaCollection(COLLECTION).ownerOf(id);
        if (agentId == 0) {
            vm.prank(holder);
            agentId = IForkAdapterRegistration(ADAPTER).register(0, COLLECTION, id, "https://example.invalid/fork-only");
        }
        (uint8 standard, address bound, uint256 boundId) = IArenaAdapter(ADAPTER).bindingOf(agentId);
        assertTrue(standard == 0 && bound == COLLECTION && boundId == id);

        NormiesArenaStorage store = new NormiesArenaStorage(
            address(pixels),
            COLLECTION,
            ADAPTER,
            0x00000000000000447e69651d841bD8D104Bed493,
            0x00000000000076A84feF008CDAbe6409d2FE638B,
            address(this)
        );
        NormiesArena arena = new NormiesArena(address(store), address(this));
        NormiesArenaQueue queue = new NormiesArenaQueue(address(store), address(this));
        NormiesArenaSkins skins = new NormiesArenaSkins(address(store), address(this), address(0x7EA));
        store.setAuthorizedWriter(address(arena), true);
        store.setAuthorizedWriter(address(queue), true);
        store.setAuthorizedWriter(address(skins), true);
        vm.startPrank(pixels.owner());
        pixels.setMoverRoles(address(store), 4);
        pixels.setMoverRoles(address(queue), 4);
        pixels.setMoverRoles(address(skins), 4);
        vm.stopPrank();
        vm.startPrank(MINTER);
        pixels.mintTo(address(this), 20);
        pixels.mintTo(holder, 20);
        vm.stopPrank();
        queue.sponsor(1, 10);
        queue.sponsor(2, 10);
        arena.setPaused(false);
        queue.setPaused(false);
        skins.setPaused(false);
        vm.prank(holder);
        queue.bindAgent(id, agentId);
        vm.prank(holder);
        queue.deposit(id, 10, true);
        vm.prank(holder);
        skins.purchase(id, 5, holder);
        // Rounds 1 and 2 free, round 3 paid at 1.
        for (uint256 round = 1; round <= 3; ++round) {
            arena.startRound(round);
            arena.admit(round, 50);
            assertEq(arena.players(round).length, 1);
            arena.finishRound(round);
            bytes32 result = keccak256(abi.encode(round, id));
            arena.postResults(round, result);
            uint256[] memory winners = new uint256[](1);
            winners[0] = id;
            arena.settle(round, result, winners);
        }
        assertEq(store.balanceOf(id), 30);
        // A sale: the new holder controls the balance.
        address buyer = address(0xB0B);
        vm.prank(holder);
        IERC721Transfer(COLLECTION).transferFrom(holder, buyer, id);
        vm.prank(holder);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(id, 1);
        vm.prank(buyer);
        store.withdraw(id, 30);
        assertEq(pixels.balanceOf(address(store)), store.totalAllocated() + store.totalPooled());
    }
}

interface IERC721Transfer {
    function transferFrom(address from, address to, uint256 id) external;
}

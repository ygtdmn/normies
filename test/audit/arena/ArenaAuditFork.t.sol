// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { Vm } from "forge-std/src/Vm.sol";
import { NormiesCanvasStorageV2 } from "../../../src/NormiesCanvasStorageV2.sol";
import { NormiesArenaStorage, IArenaAdapter } from "../../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../../../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../../../src/NormiesArenaSkins.sol";
import { ArenaAccess } from "../../../src/arena/ArenaAccess.sol";
import { AuditAdapter } from "./ArenaAuditBase.sol";

interface IForkNormies {
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

interface IForkAdapter {
    function register(uint8 standard, address collection, uint256 id, string calldata uri) external returns (uint256);
    function bindingOf(uint256 agentId) external view returns (uint8, address, uint256);
}

interface IDelegateV2 {
    function delegateAll(address to, bytes32 rights, bool enable) external payable returns (bytes32);
    function delegateContract(address to, address c, bytes32 rights, bool enable) external payable returns (bytes32);
    function delegateERC721(
        address to,
        address c,
        uint256 id,
        bytes32 rights,
        bool enable
    ) external payable returns (bytes32);
    function delegateERC20(address to, address c, bytes32 rights, uint256 amount) external payable returns (bytes32);
    function delegateERC1155(
        address to,
        address c,
        uint256 id,
        bytes32 rights,
        uint256 amount
    ) external payable returns (bytes32);
}

interface IDelegateV1 {
    function delegateForAll(address delegate, bool value) external;
    function delegateForContract(address delegate, address c, bool value) external;
    function delegateForToken(address delegate, address c, uint256 id, bool value) external;
    function revokeAllDelegates() external;
}

/**
 * @notice Mainnet-fork checks at a pinned block against the REAL pixel ledger, Normies collection, ERC-8004 adapter
 *         and delegate.xyz v1/v2 registries. Read-only on the network: everything is deployed and changed in the local
 *         fork. Skipped unless ARENA_AUDIT_FORK_URL is set. Run the gas tests with --isolate.
 */
contract ArenaAuditForkTest is Test {
    uint256 constant FORK_BLOCK = 26_409_700;
    uint256 constant GAS_CAP = 16_777_216;
    uint256 constant BASE = 21_000;
    address constant COLLECTION = 0x9Eb6E2025B64f340691e424b7fe7022fFDE12438;
    address constant ADAPTER = 0xde152AfB7db5373F34876E1499fbD893A82dD336;
    address constant MINTER = 0xF14f2852e1fD6A4108156054AF49B3915dc40E2e;
    address constant REG_V2 = 0x00000000000000447e69651d841bD8D104Bed493;
    address constant REG_V1 = 0x00000000000076A84feF008CDAbe6409d2FE638B;
    NormiesCanvasStorageV2 constant pixels = NormiesCanvasStorageV2(0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084);

    NormiesArenaStorage store;
    NormiesArena arena;
    NormiesArenaQueue queue;
    NormiesArenaSkins skins;
    AuditAdapter modelAdapter;
    bool live;
    address hot = address(0x407407);
    address treasury = address(0x7EA7EA);
    uint256 nextScan = 1;

    function setUp() public {
        string memory url = vm.envOr("ARENA_AUDIT_FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, FORK_BLOCK);
        assertEq(block.chainid, 1);
        live = true;
        store = new NormiesArenaStorage(address(pixels), COLLECTION, ADAPTER, REG_V2, REG_V1, address(this));
        arena = new NormiesArena(address(store), address(this));
        queue = new NormiesArenaQueue(address(store), address(this));
        skins = new NormiesArenaSkins(address(store), address(this), treasury);
        store.setAuthorizedWriter(address(arena), true);
        store.setAuthorizedWriter(address(queue), true);
        store.setAuthorizedWriter(address(skins), true);
        vm.startPrank(pixels.owner());
        pixels.setMoverRoles(address(store), 4);
        pixels.setMoverRoles(address(queue), 4);
        pixels.setMoverRoles(address(skins), 4);
        vm.stopPrank();
        arena.setPaused(false);
        queue.setPaused(false);
        skins.setPaused(false);
        modelAdapter = new AuditAdapter(COLLECTION);
        _mintPixels(hot, 10_000);
        _mintPixels(address(this), 10_000);
    }

    modifier onFork() {
        if (!live) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _mintPixels(address to, uint256 amount) internal {
        vm.prank(MINTER);
        pixels.mintTo(to, amount);
    }

    /// @dev The next existing Normie, moved to a fresh EOA `to` on the fork. Ids that are burned or whose transfer
    ///      the collection refuses are skipped.
    function _takeNormie(address to) internal returns (uint256 id) {
        while (true) {
            id = nextScan++;
            address holder;
            try IForkNormies(COLLECTION).ownerOf(id) returns (address h) {
                holder = h;
            } catch {
                continue;
            }
            vm.prank(holder);
            try IForkNormies(COLLECTION).transferFrom(holder, to, id) {
                return id;
            } catch {
                continue;
            }
        }
    }

    function _fresh(uint256 i) internal pure returns (address) {
        return address(uint160(0xF0F0000000 + i));
    }

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
        emit log_string(name);
        emit log_named_uint("  tx gas used (after refund)", g.gasTotalUsed);
        emit log_named_int("  refund", g.gasRefunded);
        emit log_named_uint("  MIN TX GAS LIMIT", lo + BASE);
        emit log_named_uint("  headroom under 16,777,216", GAS_CAP - lo - BASE);
        assertLt(lo + BASE, GAS_CAP);
    }

    // ───────────── delegate.xyz: real registries ─────────────

    function _can(address who, uint256 id) internal view returns (bool) {
        try store.holderFor(id, who) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Which real delegate.xyz delegations let `hot` act for a Normie, and that a withdrawal by the delegate
    ///         lands in the holder's wallet on the real ledger.
    function testFork_delegateScopesOnRealRegistries() public onFork {
        address vault = _fresh(1);
        uint256 id = _takeNormie(vault);
        uint256 other = _takeNormie(vault);
        bytes32 none = bytes32(0);
        bytes32 someRight = bytes32("arena");
        assertTrue(_can(vault, id));
        assertFalse(_can(hot, id));
        vm.startPrank(vault);

        // v2, token level, full rights.
        IDelegateV2(REG_V2).delegateERC721(hot, COLLECTION, id, none, true);
        assertTrue(_can(hot, id));
        assertFalse(_can(hot, other), "token-level delegation is for one token");
        IDelegateV2(REG_V2).delegateERC721(hot, COLLECTION, id, none, false);
        assertFalse(_can(hot, id));

        // v2, contract level, full rights.
        IDelegateV2(REG_V2).delegateContract(hot, COLLECTION, none, true);
        assertTrue(_can(hot, id) && _can(hot, other));
        IDelegateV2(REG_V2).delegateContract(hot, COLLECTION, none, false);
        // v2, contract level for another contract.
        IDelegateV2(REG_V2).delegateContract(hot, address(pixels), none, true);
        assertFalse(_can(hot, id));
        IDelegateV2(REG_V2).delegateContract(hot, address(pixels), none, false);

        // v2, wallet level, full rights.
        IDelegateV2(REG_V2).delegateAll(hot, none, true);
        assertTrue(_can(hot, id));
        IDelegateV2(REG_V2).delegateAll(hot, none, false);
        assertFalse(_can(hot, id));

        // v2 delegations limited to a named right do not count (the Arena asks for full rights).
        IDelegateV2(REG_V2).delegateAll(hot, someRight, true);
        IDelegateV2(REG_V2).delegateContract(hot, COLLECTION, someRight, true);
        IDelegateV2(REG_V2).delegateERC721(hot, COLLECTION, id, someRight, true);
        assertFalse(_can(hot, id), "sub-right delegations must not pass");
        // v2 ERC20 / ERC1155 delegations do not count.
        IDelegateV2(REG_V2).delegateERC20(hot, COLLECTION, none, 100);
        IDelegateV2(REG_V2).delegateERC1155(hot, COLLECTION, id, none, 100);
        assertFalse(_can(hot, id), "fungible delegations must not pass");

        // v1: token, contract, wallet.
        IDelegateV1(REG_V1).delegateForToken(hot, COLLECTION, id, true);
        assertTrue(_can(hot, id));
        assertFalse(_can(hot, other));
        IDelegateV1(REG_V1).delegateForToken(hot, COLLECTION, id, false);
        assertFalse(_can(hot, id));
        IDelegateV1(REG_V1).delegateForContract(hot, COLLECTION, true);
        assertTrue(_can(hot, id) && _can(hot, other));
        IDelegateV1(REG_V1).delegateForContract(hot, COLLECTION, false);
        IDelegateV1(REG_V1).delegateForContract(hot, address(pixels), true);
        assertFalse(_can(hot, id));
        IDelegateV1(REG_V1).delegateForAll(hot, true);
        assertTrue(_can(hot, id));
        vm.stopPrank();

        // The delegate tops up from its own wallet; its withdrawal pays the vault.
        uint256 hotBefore = pixels.balanceOf(hot);
        vm.prank(hot);
        queue.deposit(id, 25, false);
        assertEq(pixels.balanceOf(hot), hotBefore - 25);
        uint256 vaultBefore = pixels.balanceOf(vault);
        vm.prank(hot);
        store.withdraw(id, 10);
        assertEq(pixels.balanceOf(vault), vaultBefore + 10);
        assertEq(pixels.balanceOf(hot), hotBefore - 25);
        // v1 revokeAllDelegates removes control at once.
        vm.prank(vault);
        IDelegateV1(REG_V1).revokeAllDelegates();
        assertFalse(_can(hot, id));
        // After a sale, the old vault and its delegates have no say.
        vm.prank(vault);
        IDelegateV2(REG_V2).delegateAll(hot, none, true);
        assertTrue(_can(hot, id));
        vm.prank(vault);
        IForkNormies(COLLECTION).transferFrom(vault, _fresh(2), id);
        assertFalse(_can(hot, id));
        assertFalse(_can(vault, id));
        vm.prank(_fresh(2));
        store.withdraw(id, 15);
        assertEq(pixels.balanceOf(_fresh(2)), 15);
        assertEq(pixels.balanceOf(address(store)), store.totalAllocated() + store.totalPooled());
    }

    // ───────────── ERC-8004 adapter: real contract ─────────────

    /// @notice Who can create a binding for a Normie on the real adapter, whether one Normie can have several agents,
    ///         and what permissionless bindAgent can do with that.
    function testFork_adapterBindingRules() public onFork {
        address holder = _fresh(3);
        uint256 id = _takeNormie(holder);
        // A stranger cannot register an agent for someone else's Normie.
        vm.prank(address(0xBEEF));
        (bool strangerOk,) = ADAPTER.call(
            abi.encodeCall(IForkAdapter.register, (0, COLLECTION, id, "https://example.invalid/audit"))
        );
        emit log_named_string("stranger can register an agent for the Normie", strangerOk ? "YES" : "no");
        // The holder registers one agent, then tries a second for the same Normie.
        vm.prank(holder);
        uint256 a1 = IForkAdapter(ADAPTER).register(0, COLLECTION, id, "https://example.invalid/audit-1");
        (uint8 s1, address c1, uint256 t1) = IForkAdapter(ADAPTER).bindingOf(a1);
        assertTrue(s1 == 0 && c1 == COLLECTION && t1 == id);
        vm.prank(holder);
        (bool secondOk, bytes memory ret) = ADAPTER.call(
            abi.encodeCall(IForkAdapter.register, (0, COLLECTION, id, "https://example.invalid/audit-2"))
        );
        emit log_named_string("holder can register a second agent for the same Normie", secondOk ? "YES" : "no");
        queue.bindAgent(id, a1);
        assertEq(store.agentOf(id), a1);
        if (secondOk) {
            uint256 a2 = abi.decode(ret, (uint256));
            (uint8 s2, address c2, uint256 t2) = IForkAdapter(ADAPTER).bindingOf(a2);
            bool bothPoint = s2 == 0 && c2 == COLLECTION && t2 == id;
            emit log_named_string("both agents' bindings point at the Normie", bothPoint ? "YES" : "no");
            if (bothPoint) {
                // Anyone can then move the Arena link between them.
                vm.prank(address(0xBEEF));
                queue.bindAgent(id, a2);
                assertEq(store.agentOf(id), a2);
                emit log_string("a stranger re-pointed the Arena link from the first agent to the second");
            }
        }
        // After a sale the binding still points at the Normie, so the new holder joins with the old link.
        vm.prank(holder);
        IForkNormies(COLLECTION).transferFrom(holder, _fresh(4), id);
        (, address c3, uint256 t3) = IForkAdapter(ADAPTER).bindingOf(a1);
        emit log_named_string(
            "after a sale the first agent's binding still points at the Normie", (c3 == COLLECTION && t3 == id) ? "YES" : "no"
        );
        // A stranger cannot link an agent that is bound to another Normie.
        uint256 other = _takeNormie(_fresh(5));
        vm.expectRevert(ArenaAccess.InvalidInput.selector);
        queue.bindAgent(other, a1);
    }

    // ───────────── gas on the fork (run with --isolate) ─────────────

    /// @dev `n` real Normies moved to `n` distinct fresh holders, linked through the model adapter (the adapter is
    ///      only read when joining, never in admit, settle, cancel or withdraw) and joined with `balance` pixels.
    function _seedLine(uint256 n, uint256 balance) internal returns (uint256[] memory ids) {
        store.setAdapter(address(modelAdapter));
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address holder = _fresh(100 + i);
            uint256 id = _takeNormie(holder);
            ids[i] = id;
            modelAdapter.bind(id, id);
            queue.bindAgent(id, id);
            _mintPixels(holder, balance);
            vm.prank(holder);
            queue.deposit(id, balance, true);
        }
    }

    function _admitAll(uint256 round) internal {
        for (uint256 i; i < 50 && !store.roundOf(round).closed; ++i) {
            arena.admit(round, arena.maxScan());
        }
        assertTrue(store.roundOf(round).closed);
    }

    function testFork_gas_settle_and_cancel_300_all_returning() public onFork {
        arena.setCapacity(300);
        arena.setWinnerBps(10_000);
        arena.setMaxScan(80);
        arena.setFreeRound(1, false);
        arena.setFreeRound(2, false);
        queue.sponsor(1, 77);
        uint256[] memory ids = _seedLine(300, 1);
        arena.startRound(1);
        _admitAll(1);
        assertEq(store.playerCount(1), 300);
        arena.finishRound(1);
        bytes32 h = keccak256("r");
        arena.postResults(1, h);
        arena.startRound(2);
        _admitAll(2);
        assertEq(store.playerCount(2), 0);
        (,, bool needs) = store.enrollment(ids[299]);
        assertTrue(needs);
        uint256[] memory winners = arena.players(1);
        _measure(
            "FORK settle: 300 winners, all short, all returning (real collection)",
            address(this),
            address(arena),
            abi.encodeCall(arena.settle, (1, h, winners))
        );
        _measure(
            "FORK cancel: 300 players, all short, all returning (real collection)",
            address(this),
            address(arena),
            abi.encodeCall(arena.cancel, (1))
        );
    }

    function testFork_gas_admit_80_all_seated() public onFork {
        arena.setCapacity(300);
        arena.setMaxScan(80);
        arena.setFreeRound(1, false);
        _seedLine(80, 2);
        arena.startRound(1);
        _measure(
            "FORK admit(80): all seated in a paid round (real collection)",
            address(this),
            address(arena),
            abi.encodeCall(arena.admit, (1, 80))
        );
    }

    function testFork_gas_withdrawBatch_100_by_real_v1_delegate() public onFork {
        store.setAdapter(address(modelAdapter));
        uint256[] memory ids = new uint256[](100);
        uint256[] memory amounts = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            address holder = _fresh(1000 + i);
            ids[i] = _takeNormie(holder);
            amounts[i] = 3;
            vm.prank(holder);
            IDelegateV1(REG_V1).delegateForAll(hot, true);
            vm.prank(hot);
            queue.deposit(ids[i], 3, false);
            assertEq(pixels.balanceOf(holder), 0);
        }
        _measure(
            "FORK withdrawBatch(100): real v1 wallet-level delegate, 100 distinct fresh holders, real ledger",
            hot,
            address(store),
            abi.encodeCall(store.withdrawBatch, (ids, amounts))
        );
    }

    function testFork_gas_depositRegisteredBatch_50_real_adapter_real_v1_delegate() public onFork {
        uint256[] memory ids = new uint256[](50);
        uint256[] memory amounts = new uint256[](50);
        uint256[] memory agents = new uint256[](50);
        for (uint256 i; i < 50; ++i) {
            address holder = _fresh(2000 + i);
            ids[i] = _takeNormie(holder);
            amounts[i] = 3;
            vm.startPrank(holder);
            agents[i] = IForkAdapter(ADAPTER).register(0, COLLECTION, ids[i], "https://example.invalid/audit");
            IDelegateV1(REG_V1).delegateForAll(hot, true);
            vm.stopPrank();
        }
        _measure(
            "FORK depositRegisteredBatch(50): real adapter, real v1 wallet-level delegate, 50 distinct holders",
            hot,
            address(queue),
            abi.encodeCall(queue.depositRegisteredBatch, (ids, amounts, agents))
        );
    }
}

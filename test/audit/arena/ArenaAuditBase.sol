// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { Normies } from "../../../src/Normies.sol";
import { NormiesCanvasStorageV2 } from "../../../src/NormiesCanvasStorageV2.sol";
import { NormiesArenaStorage } from "../../../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../../../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../../../src/NormiesArena.sol";
import { NormiesArenaSkins } from "../../../src/NormiesArenaSkins.sol";
import { INormiesRenderer } from "../../../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../../../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../../../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvasV1 } from "../../../src/interfaces/INormiesCanvasV1.sol";

/// @notice AUDIT MODEL of delegate.xyz v2 `checkDelegateForERC721`: wallet, contract and token level, full rights
///         only when `rights` is empty. Three storage reads when nothing matches, as in the real registry.
contract AuditDelegateRegistryV2 {
    mapping(bytes32 => bool) internal _d;

    function delegateAll(address to, address from, bool on) external {
        _d[keccak256(abi.encode(uint8(1), to, from))] = on;
    }

    function delegateContract(address to, address from, address c, bool on) external {
        _d[keccak256(abi.encode(uint8(2), to, from, c))] = on;
    }

    function delegateERC721(address to, address from, address c, uint256 id, bool on) external {
        _d[keccak256(abi.encode(uint8(3), to, from, c, id))] = on;
    }

    function checkDelegateForERC721(
        address to,
        address from,
        address c,
        uint256 id,
        bytes32 rights
    ) external view returns (bool) {
        if (rights != bytes32(0)) return false;
        return _d[keccak256(abi.encode(uint8(1), to, from))] || _d[keccak256(abi.encode(uint8(2), to, from, c))]
            || _d[keccak256(abi.encode(uint8(3), to, from, c, id))];
    }
}

/// @notice AUDIT MODEL of delegate.xyz v1 `checkDelegateForToken`: token level first, then contract, then wallet,
///         each reading the vault version, the delegate version and the delegation set, as in the real registry.
contract AuditDelegateRegistryV1 {
    mapping(address => uint256) internal vaultVersion;
    mapping(address => mapping(address => uint256)) internal delegateVersion;
    mapping(address => mapping(uint256 => mapping(bytes32 => uint256))) internal _set;

    function delegateForAll(address delegate, address vault, bool on) external {
        _set[vault][vaultVersion[vault]][_hAll(delegate, vault)] = on ? 1 : 0;
    }

    function delegateForContract(address delegate, address vault, address c, bool on) external {
        _set[vault][vaultVersion[vault]][_hContract(delegate, vault, c)] = on ? 1 : 0;
    }

    function delegateForToken(address delegate, address vault, address c, uint256 id, bool on) external {
        _set[vault][vaultVersion[vault]][_hToken(delegate, vault, c, id)] = on ? 1 : 0;
    }

    function _hAll(address d, address v) internal view returns (bytes32) {
        return keccak256(abi.encode(d, v, vaultVersion[v], delegateVersion[v][d]));
    }

    function _hContract(address d, address v, address c) internal view returns (bytes32) {
        return keccak256(abi.encode(d, v, c, vaultVersion[v], delegateVersion[v][d]));
    }

    function _hToken(address d, address v, address c, uint256 id) internal view returns (bytes32) {
        return keccak256(abi.encode(d, v, c, id, vaultVersion[v], delegateVersion[v][d]));
    }

    function checkDelegateForAll(address d, address v) public view returns (bool) {
        return _set[v][vaultVersion[v]][_hAll(d, v)] != 0;
    }

    function checkDelegateForContract(address d, address v, address c) public view returns (bool) {
        return _set[v][vaultVersion[v]][_hContract(d, v, c)] != 0 ? true : checkDelegateForAll(d, v);
    }

    function checkDelegateForToken(address d, address v, address c, uint256 id) public view returns (bool) {
        return _set[v][vaultVersion[v]][_hToken(d, v, c, id)] != 0 ? true : checkDelegateForContract(d, v, c);
    }
}

/// @notice AUDIT MODEL of the ERC-8004 adapter: one binding per agent id, ERC-721 standard 0.
contract AuditAdapter {
    address public immutable collection;
    mapping(uint256 => uint256) public bound; // agentId => tokenId + 1

    constructor(address collection_) {
        collection = collection_;
    }

    function bind(uint256 agentId, uint256 id) external {
        bound[agentId] = id + 1;
    }

    function unbind(uint256 agentId) external {
        delete bound[agentId];
    }

    function bindingOf(uint256 agentId) external view returns (uint8, address, uint256) {
        require(bound[agentId] != 0, "no binding");
        return (0, collection, bound[agentId] - 1);
    }
}

/// @notice The Arena wired to the REAL Normies collection (ERC721C) and the REAL pixel ledger
///         (NormiesCanvasStorageV2) from this repo. The delegate registries and the adapter are audit models.
abstract contract ArenaAuditBase is Test {
    address constant TRANSFER_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    uint256 constant GAS_CAP = 16_777_216;

    Normies normies;
    NormiesCanvasStorageV2 ledger;
    AuditAdapter adapter;
    AuditDelegateRegistryV2 regV2;
    AuditDelegateRegistryV1 regV1;
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
        vm.etch(TRANSFER_VALIDATOR, hex"00");
        normies = new Normies(INormiesRenderer(address(0)), INormiesStorage(address(0)), address(this));
        ledger = new NormiesCanvasStorageV2(INormiesCanvasStorage(address(0)), INormiesCanvasV1(address(0)));
        ledger.setMoverRoles(address(this), ledger.ROLE_CANVAS());
        adapter = new AuditAdapter(address(normies));
        regV2 = new AuditDelegateRegistryV2();
        regV1 = new AuditDelegateRegistryV1();
        store = new NormiesArenaStorage(
            address(ledger), address(normies), address(adapter), address(regV2), address(regV1), address(this)
        );
        arena = new NormiesArena(address(store), address(this));
        queue = new NormiesArenaQueue(address(store), address(this));
        skins = new NormiesArenaSkins(address(store), address(this), treasury);
        store.setAuthorizedWriter(address(arena), true);
        store.setAuthorizedWriter(address(queue), true);
        store.setAuthorizedWriter(address(skins), true);
        ledger.setMoverRoles(address(store), ledger.ROLE_WRAPPER());
        ledger.setMoverRoles(address(queue), ledger.ROLE_WRAPPER());
        ledger.setMoverRoles(address(skins), ledger.ROLE_WRAPPER());
        arena.grantRoles(operator, arena.OPERATOR_ROLE());
        arena.grantRoles(guardian, 1);
        queue.grantRoles(sponsorWallet, queue.SPONSOR_ROLE());
        address[5] memory funded = [alice, bob, carol, hot, sponsorWallet];
        for (uint256 i; i < 5; ++i) {
            ledger.mintTo(funded[i], 100_000);
        }
        arena.setPaused(false);
        queue.setPaused(false);
        skins.setPaused(false);
    }

    /// @dev Sponsors rounds 1 and 2 with 100 each, as the existing suite does.
    function sponsorFreeRounds() internal {
        vm.startPrank(sponsorWallet);
        queue.sponsor(1, 100);
        queue.sponsor(2, 100);
        vm.stopPrank();
    }

    /// @dev Mints Normie `id` to `who` on the real collection and binds agent `id` to it on the adapter model.
    function give(uint256 id, address who) internal {
        normies.mint(who, id);
        adapter.bind(id, id);
    }

    /// @dev Mints Normie `id` to `who`, links its agent and joins the line with `amount` pixels.
    function join(uint256 id, address who, uint256 amount) internal {
        give(id, who);
        vm.prank(who);
        queue.bindAgent(id, id);
        vm.prank(who);
        queue.deposit(id, amount, true);
    }

    function transferNormie(uint256 id, address to) internal {
        address from = normies.ownerOf(id);
        vm.prank(from);
        normies.transferFrom(from, to, id);
    }

    function burnNormie(uint256 id) internal {
        address from = normies.ownerOf(id);
        vm.prank(from);
        normies.burn(id);
    }

    function openRound(uint256 round) internal {
        uint256 current = store.currentRound();
        if (current == round && store.isOpen(round)) return;
        while (current < round) {
            if (store.isOpen(current)) arena.finishRound(current);
            arena.startRound(++current);
        }
        assertTrue(store.isOpen(round));
    }

    function admitAll(uint256 round) internal {
        openRound(round);
        for (uint256 i; i < 200 && !store.roundOf(round).closed; ++i) {
            arena.admit(round, arena.maxScan());
        }
        assertTrue(store.roundOf(round).closed);
    }

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

    function assertBacked() internal view {
        assertEq(ledger.balanceOf(address(store)), store.totalAllocated() + store.totalPooled(), "backing");
    }
}

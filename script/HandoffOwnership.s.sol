// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script, console } from "forge-std/src/Script.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { NormiesCanvasV2 } from "../src/NormiesCanvasV2.sol";
import { NormiesPixelMarket } from "../src/NormiesPixelMarket.sol";
import { NormiesRendererV6 } from "../src/NormiesRendererV6.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { NormiesRoyaltySplitter } from "../src/NormiesRoyaltySplitter.sol";
import { OwnableRoles } from "solady/auth/OwnableRoles.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @notice Moves the V2 stack off the deployer key. After it:
 *
 *           Admin Safe         owns storage V2, canvas V2, market, renderer V6
 *           Treasury Safe      owns revenue pool, royalty splitter
 *           Operations Safe    GUARDIAN (pause and unpause, allowance kill switch, cancel an unopened epoch)
 *                              and CONFIG (prices, tiers, fees, floor, claim window) on canvas, market, pool;
 *                              GUARDIAN on storage V2
 *           Revshare job key   POSTER on the pool: postEpoch only; claims open 24 h later
 *           Deployer           nothing: no role, Lifebuoy rescue locked
 *
 *         No owner reaches both the pixel ledger and the ETH, and no single key holds any of these powers. Run it
 *         after the cutover (migration and delegations finalized), from the deployer. Every step is skipped when
 *         already done, so a run that stopped half way is simply rerun. Unpausing comes after, from the Operations
 *         Safe.
 *
 *         MODE=handoff (default) does the above. MODE=check is read-only and passes only when every piece is in
 *         place.
 *
 * Env: CANVAS_STORAGE_V2_ADDRESS, CANVAS_V2_ADDRESS, MARKET_ADDRESS, RENDERER_V6_ADDRESS, REVENUE_POOL_ADDRESS,
 *      ROYALTY_SPLITTER_ADDRESS, ADMIN_SAFE, TREASURY_SAFE, OPERATIONS_SAFE, REVSHARE_POSTER; optional MODE,
 *      DEPLOYER (check mode).
 */
contract HandoffOwnership is Script {
    /// @dev The role bits of NormiesAccess (internal there): GUARDIAN, CONFIG, POSTER.
    uint256 public constant GUARDIAN = 1 << 0;
    uint256 public constant CONFIG = 1 << 1;
    uint256 public constant POSTER = 1 << 2;
    uint256 internal constant DEPLOYER_RESCUE_LOCK = 1;

    struct Stack {
        NormiesCanvasStorageV2 storageV2;
        NormiesCanvasV2 canvas;
        NormiesPixelMarket market;
        NormiesRendererV6 renderer;
        NormiesRevenuePool pool;
        NormiesRoyaltySplitter splitter;
    }

    struct Holders {
        address adminSafe;
        address treasurySafe;
        address operationsSafe;
        address poster;
    }

    function run() public {
        Stack memory s = _stack();
        Holders memory h = Holders(
            vm.envAddress("ADMIN_SAFE"),
            vm.envAddress("TREASURY_SAFE"),
            vm.envAddress("OPERATIONS_SAFE"),
            vm.envAddress("REVSHARE_POSTER")
        );
        string memory mode = vm.envOr("MODE", string("handoff"));
        if (keccak256(bytes(mode)) == keccak256("check")) {
            check(s, h, vm.envOr("DEPLOYER", address(0)));
        } else {
            require(keccak256(bytes(mode)) == keccak256("handoff"), "MODE must be handoff or check");
            handoff(s, h, msg.sender);
        }
    }

    /// @notice What the deployer sends. Every precondition is checked before the first transaction.
    function handoff(Stack memory s, Holders memory h, address deployer) public {
        _checkHolders(h, deployer);
        require(s.storageV2.migrationFinalized(), "finalize the balance migration first (MigrateLegacy.s.sol)");
        require(s.storageV2.delegationsSeeded(), "copy the delegations first (pnpm cutover:delegations)");
        require(s.storageV2.moverRoles(deployer) == 0, "the deployer still holds a mover role on storage V2");
        require(!s.storageV2.authorizedWriters(deployer), "the deployer is still an overlay writer on storage V2");
        require(
            s.storageV2.moverRoles(address(s.canvas)) == s.storageV2.ROLE_CANVAS(), "canvas V2 is not the canvas mover"
        );
        require(
            s.storageV2.moverRoles(address(s.market)) == s.storageV2.ROLE_MARKET(), "the market is not the market mover"
        );
        require(s.market.revenueShareRecipient() == address(s.pool), "market fees do not go to the revenue pool");
        require(s.splitter.pool() == address(s.pool), "the royalty splitter does not pay this pool");

        vm.startBroadcast(deployer);
        // Roles first, while the deployer still owns everything.
        _grant(s.storageV2, h.operationsSafe, GUARDIAN, deployer);
        _grant(s.canvas, h.operationsSafe, GUARDIAN | CONFIG, deployer);
        _grant(s.market, h.operationsSafe, GUARDIAN | CONFIG, deployer);
        _grant(s.pool, h.operationsSafe, GUARDIAN | CONFIG, deployer);
        _grant(s.pool, h.poster, POSTER, deployer);

        _lockDeployerRescue(address(s.storageV2));
        _lockDeployerRescue(address(s.canvas));
        _lockDeployerRescue(address(s.market));
        _lockDeployerRescue(address(s.renderer));

        _transfer(address(s.storageV2), h.adminSafe, deployer);
        _transfer(address(s.canvas), h.adminSafe, deployer);
        _transfer(address(s.market), h.adminSafe, deployer);
        _transfer(address(s.renderer), h.adminSafe, deployer);
        _transfer(address(s.pool), h.treasurySafe, deployer);
        _transfer(address(s.splitter), h.treasurySafe, deployer);
        vm.stopBroadcast();

        console.log("now run MODE=check with DEPLOYER set");
    }

    /// @notice Read-only verification. Reverts naming the first thing that is not in place.
    function check(Stack memory s, Holders memory h, address deployer) public view {
        _checkHolders(h, deployer);

        _owned(address(s.storageV2), h.adminSafe, "storage V2 is not owned by the Admin Safe");
        _owned(address(s.canvas), h.adminSafe, "canvas V2 is not owned by the Admin Safe");
        _owned(address(s.market), h.adminSafe, "the market is not owned by the Admin Safe");
        _owned(address(s.renderer), h.adminSafe, "renderer V6 is not owned by the Admin Safe");
        _owned(address(s.pool), h.treasurySafe, "the revenue pool is not owned by the Treasury Safe");
        _owned(address(s.splitter), h.treasurySafe, "the royalty splitter is not owned by the Treasury Safe");

        _exactRoles(s.storageV2, h.operationsSafe, GUARDIAN, "operations on storage V2");
        _exactRoles(s.canvas, h.operationsSafe, GUARDIAN | CONFIG, "operations on canvas V2");
        _exactRoles(s.market, h.operationsSafe, GUARDIAN | CONFIG, "operations on market");
        _exactRoles(s.pool, h.operationsSafe, GUARDIAN | CONFIG, "operations on pool");
        _exactRoles(s.pool, h.poster, POSTER, "poster on pool");
        _exactRoles(s.storageV2, h.poster, 0, "poster on storage V2");
        _exactRoles(s.canvas, h.poster, 0, "poster on canvas V2");
        _exactRoles(s.market, h.poster, 0, "poster on market");

        _rescueLocked(address(s.storageV2), "storage V2");
        _rescueLocked(address(s.canvas), "canvas V2");
        _rescueLocked(address(s.market), "market");
        _rescueLocked(address(s.renderer), "renderer V6");

        if (deployer != address(0)) {
            _exactRoles(s.storageV2, deployer, 0, "deployer on storage V2");
            _exactRoles(s.canvas, deployer, 0, "deployer on canvas V2");
            _exactRoles(s.market, deployer, 0, "deployer on market");
            _exactRoles(s.pool, deployer, 0, "deployer on pool");
            require(s.storageV2.moverRoles(deployer) == 0, "the deployer holds a mover role on storage V2");
            require(!s.storageV2.authorizedWriters(deployer), "the deployer is an overlay writer on storage V2");
        } else {
            console.log("DEPLOYER not set: the deployer's roles were not checked");
        }
        console.log("handoff verified");
    }

    // ──────────────────────────────────────────────
    //  Steps (each skipped when already done)
    // ──────────────────────────────────────────────

    function _grant(OwnableRoles target, address holder, uint256 roles, address deployer) internal {
        if (target.owner() != deployer) return; // already handed off
        if (!target.hasAllRoles(holder, roles)) target.grantRoles(holder, roles);
    }

    function _lockDeployerRescue(address target) internal {
        if (Lifebuoy(payable(target)).rescueLocked() & DEPLOYER_RESCUE_LOCK == 0) {
            Lifebuoy(payable(target)).lockRescue(DEPLOYER_RESCUE_LOCK);
        }
    }

    /// @dev Single-step on purpose: the target is a Safe `_checkHolders` already found code at, and the three Safes
    ///      are checked to be distinct, so a mistyped address cannot get here. Later moves use the two-step handover.
    function _transfer(address target, address safe, address deployer) internal {
        address current = Ownable(target).owner();
        if (current == safe) return;
        require(current == deployer, "a contract is owned by neither the deployer nor its Safe");
        Ownable(target).transferOwnership(safe);
    }

    // ──────────────────────────────────────────────
    //  Checks
    // ──────────────────────────────────────────────

    function _checkHolders(Holders memory h, address deployer) internal view {
        require(h.adminSafe.code.length > 0, "ADMIN_SAFE has no code: is it deployed on this chain?");
        require(h.treasurySafe.code.length > 0, "TREASURY_SAFE has no code: is it deployed on this chain?");
        require(h.operationsSafe.code.length > 0, "OPERATIONS_SAFE has no code: is it deployed on this chain?");
        // The pixel ledger and the ETH never sit behind the same owner, and the guardian is its own Safe.
        require(h.adminSafe != h.treasurySafe, "the Admin and Treasury Safes must differ");
        require(
            h.operationsSafe != h.adminSafe && h.operationsSafe != h.treasurySafe,
            "the Operations Safe must differ from Admin and Treasury"
        );
        require(h.poster != address(0) && h.poster != deployer, "REVSHARE_POSTER must be its own gas-only key");
        require(
            h.poster != h.adminSafe && h.poster != h.treasurySafe && h.poster != h.operationsSafe,
            "REVSHARE_POSTER must not be a Safe"
        );
    }

    function _owned(address target, address owner, string memory what) internal view {
        require(Ownable(target).owner() == owner, what);
    }

    function _exactRoles(OwnableRoles target, address holder, uint256 roles, string memory what) internal view {
        require(target.rolesOf(holder) == roles, string.concat("wrong roles: ", what));
    }

    function _rescueLocked(address target, string memory name) internal view {
        require(
            Lifebuoy(payable(target)).rescueLocked() & DEPLOYER_RESCUE_LOCK != 0,
            string.concat(name, ": the deployer's rescue access is not locked")
        );
    }

    function _stack() internal view returns (Stack memory s) {
        s.storageV2 = NormiesCanvasStorageV2(vm.envAddress("CANVAS_STORAGE_V2_ADDRESS"));
        s.canvas = NormiesCanvasV2(vm.envAddress("CANVAS_V2_ADDRESS"));
        s.market = NormiesPixelMarket(vm.envAddress("MARKET_ADDRESS"));
        s.renderer = NormiesRendererV6(vm.envAddress("RENDERER_V6_ADDRESS"));
        s.pool = NormiesRevenuePool(payable(vm.envAddress("REVENUE_POOL_ADDRESS")));
        s.splitter = NormiesRoyaltySplitter(payable(vm.envAddress("ROYALTY_SPLITTER_ADDRESS")));
    }
}

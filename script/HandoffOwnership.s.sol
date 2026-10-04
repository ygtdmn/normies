// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script, console } from "forge-std/src/Script.sol";
import { VmSafe } from "forge-std/src/Vm.sol";
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
 *           Treasury Safe      owns revenue pool, royalty splitter (TREASURY_SAFE; defaults to the Admin Safe,
 *                              which is the launch layout)
 *           Operations Safe    GUARDIAN (pause and unpause, allowance kill switch, cancel an unopened epoch)
 *                              and CONFIG (prices, tiers, fees, floor, claim window) on canvas, market, pool;
 *                              GUARDIAN on storage V2
 *           Revshare job key   POSTER on the pool: postEpoch only; claims open 24 h later
 *           Deployer           nothing: no role, Lifebuoy rescue locked
 *
 *         No single key holds any of these powers, and the guardian is its own Safe with its own signers. Run it
 *         after the cutover (migration and delegations finalized), from the deployer. Every step is skipped when
 *         already done, so a run that stopped half way is simply rerun. Unpausing comes after, from the Operations
 *         Safe.
 *
 *         Both modes first check that the Safes are real multisigs: Admin at least 3 signers required, a separate
 *         Treasury and Operations at least 2, no two distinct Safes with the same signer set, and the poster key a
 *         signer of none.
 *
 *         MODE=handoff (default) does the above. MODE=check is read-only and passes only when every piece is in
 *         place. It also replays every RolesUpdated, MoverRolesSet and AuthorizedWriterSet event since
 *         DEPLOY_BLOCK, so a role, mover or writer held by any address outside the expected list fails it, and it
 *         prints the fee and royalty recipients and the Safe thresholds for the runbook. With NORMIES_ADDRESS set it
 *         also requires the Normies NFT to be owned by the Admin Safe, with the deployer's rescue access locked.
 *
 * Env: CANVAS_STORAGE_V2_ADDRESS, CANVAS_V2_ADDRESS, MARKET_ADDRESS, RENDERER_V6_ADDRESS, REVENUE_POOL_ADDRESS,
 *      ROYALTY_SPLITTER_ADDRESS, ADMIN_SAFE, OPERATIONS_SAFE, REVSHARE_POSTER; optional MODE, TREASURY_SAFE.
 *      Check mode: DEPLOY_BLOCK (required, the block the V2 stack was deployed in), DEPLOYER, EXTRA_WRITERS
 *      (comma separated overlay writers besides canvas V2, e.g. the bot key), NORMIES_ADDRESS.
 */
/// @dev The two Safe reads the checks need.
interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

contract HandoffOwnership is Script {
    /// @dev The role bits of NormiesAccess (internal there): GUARDIAN, CONFIG, POSTER.
    uint256 public constant GUARDIAN = 1 << 0;
    uint256 public constant CONFIG = 1 << 1;
    uint256 public constant POSTER = 1 << 2;
    uint256 internal constant DEPLOYER_RESCUE_LOCK = 1;
    uint256 public constant MIN_ADMIN_THRESHOLD = 3;
    uint256 public constant MIN_THRESHOLD = 2;

    struct Stack {
        NormiesCanvasStorageV2 storageV2;
        NormiesCanvasV2 canvas;
        NormiesPixelMarket market;
        NormiesRendererV6 renderer;
        NormiesRevenuePool pool;
        NormiesRoyaltySplitter splitter;
        /// @dev Optional (zero skips it): the Normies NFT, which moves to the Admin Safe after the renderer flip and
        ///      the royalty change.
        address normies;
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
            vm.envOr("TREASURY_SAFE", vm.envAddress("ADMIN_SAFE")),
            vm.envAddress("OPERATIONS_SAFE"),
            vm.envAddress("REVSHARE_POSTER")
        );
        string memory mode = vm.envOr("MODE", string("handoff"));
        if (keccak256(bytes(mode)) == keccak256("check")) {
            check(s, h, vm.envOr("DEPLOYER", address(0)));
            address[] memory none;
            checkHistory(s, h, vm.envOr("EXTRA_WRITERS", ",", none), _roleLogs(s, vm.envUint("DEPLOY_BLOCK")));
            console.log("handoff verified");
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

        console.log("now run MODE=check with DEPLOY_BLOCK and DEPLOYER set");
    }

    /// @notice Read-only verification of the current state. Reverts naming the first thing that is not in place.
    function check(Stack memory s, Holders memory h, address deployer) public view {
        _checkHolders(h, deployer);

        _owned(address(s.storageV2), h.adminSafe, "storage V2 is not owned by the Admin Safe");
        _owned(address(s.canvas), h.adminSafe, "canvas V2 is not owned by the Admin Safe");
        _owned(address(s.market), h.adminSafe, "the market is not owned by the Admin Safe");
        _owned(address(s.renderer), h.adminSafe, "renderer V6 is not owned by the Admin Safe");
        _owned(address(s.pool), h.treasurySafe, "the revenue pool is not owned by the Treasury Safe (TREASURY_SAFE)");
        _owned(
            address(s.splitter),
            h.treasurySafe,
            "the royalty splitter is not owned by the Treasury Safe (TREASURY_SAFE)"
        );

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

        if (s.normies != address(0)) {
            _owned(s.normies, h.adminSafe, "the Normies NFT is not owned by the Admin Safe");
            _rescueLocked(s.normies, "Normies");
        } else {
            console.log("NORMIES_ADDRESS not set: the Normies NFT owner was not checked");
        }

        // For the runbook: who receives what, and how many signers each Safe needs.
        console.log("market treasury recipient ", s.market.treasuryRecipient());
        console.log("market revenue share      ", s.market.revenueShareRecipient());
        console.log("splitter team             ", s.splitter.team());
        console.log("splitter pool             ", s.splitter.pool());
        console.log("admin safe threshold      ", ISafe(h.adminSafe).getThreshold());
        console.log("treasury safe threshold   ", ISafe(h.treasurySafe).getThreshold());
        console.log("operations safe threshold ", ISafe(h.operationsSafe).getThreshold());
    }

    /**
     * @notice Roles, movers and writers cannot be enumerated on chain, so this walks every event that ever set one
     *         (`logs`, from the deployment on) and requires each address it names to hold exactly what the layout
     *         gives it now: the Operations Safe and the poster their roles, canvas V2 and the market their mover
     *         roles, canvas V2 and `extraWriters` a writer slot, everyone else nothing.
     */
    function checkHistory(
        Stack memory s,
        Holders memory h,
        address[] memory extraWriters,
        VmSafe.Log[] memory logs
    ) public view {
        require(s.storageV2.authorizedWriters(address(s.canvas)), "canvas V2 is not an overlay writer on storage V2");
        uint256 replayed;
        for (uint256 i; i < logs.length; ++i) {
            VmSafe.Log memory l = logs[i];
            if (l.topics.length < 2) continue;
            address who = address(uint160(uint256(l.topics[1])));
            if (l.topics[0] == OwnableRoles.RolesUpdated.selector && _isRoleContract(s, l.emitter)) {
                require(
                    OwnableRoles(l.emitter).rolesOf(who) == _expectedRoles(s, h, l.emitter, who),
                    string.concat("unexpected roles on ", vm.toString(l.emitter), " for ", vm.toString(who))
                );
            } else if (
                l.emitter == address(s.storageV2) && l.topics[0] == NormiesCanvasStorageV2.MoverRolesSet.selector
            ) {
                uint8
                    want = who == address(s.canvas)
                        ? s.storageV2.ROLE_CANVAS()
                        : who == address(s.market) ? s.storageV2.ROLE_MARKET() : 0;
                require(
                    s.storageV2.moverRoles(who) == want, string.concat("unexpected mover role for ", vm.toString(who))
                );
            } else if (
                l.emitter == address(s.storageV2) && l.topics[0] == NormiesCanvasStorageV2.AuthorizedWriterSet.selector
            ) {
                bool want = who == address(s.canvas) || _contains(extraWriters, who);
                require(
                    s.storageV2.authorizedWriters(who) == want,
                    string.concat(want ? "missing" : "unexpected", " overlay writer ", vm.toString(who))
                );
            } else {
                continue;
            }
            ++replayed;
        }
        require(replayed > 0, "no role events found: is DEPLOY_BLOCK at or before the deployment?");
        console.log("role events replayed      ", replayed);
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
        _checkSafe(h.adminSafe, MIN_ADMIN_THRESHOLD, "ADMIN_SAFE");
        if (h.treasurySafe != h.adminSafe) _checkSafe(h.treasurySafe, MIN_THRESHOLD, "TREASURY_SAFE");
        _checkSafe(h.operationsSafe, MIN_THRESHOLD, "OPERATIONS_SAFE");
        // The Admin Safe may also own the pool and splitter; the guardian is always its own Safe.
        require(
            h.operationsSafe != h.adminSafe && h.operationsSafe != h.treasurySafe,
            "the Operations Safe must differ from Admin and Treasury"
        );
        require(h.poster != address(0) && h.poster != deployer, "REVSHARE_POSTER must be its own gas-only key");
        require(
            h.poster != h.adminSafe && h.poster != h.treasurySafe && h.poster != h.operationsSafe,
            "REVSHARE_POSTER must not be a Safe"
        );
        address[] memory admin = ISafe(h.adminSafe).getOwners();
        address[] memory treasury = ISafe(h.treasurySafe).getOwners();
        address[] memory operations = ISafe(h.operationsSafe).getOwners();
        if (h.treasurySafe != h.adminSafe) {
            require(!_sameSet(admin, treasury), "the Admin and Treasury Safes have the same signers");
        }
        require(!_sameSet(admin, operations), "the Admin and Operations Safes have the same signers");
        require(!_sameSet(treasury, operations), "the Treasury and Operations Safes have the same signers");
        require(
            !_contains(admin, h.poster) && !_contains(treasury, h.poster) && !_contains(operations, h.poster),
            "REVSHARE_POSTER is a Safe signer; it lives on the API host and must sign nothing"
        );
    }

    /// @dev Has code, answers as a Safe, and needs at least `minThreshold` of its signers.
    function _checkSafe(address safe, uint256 minThreshold, string memory name) internal view {
        require(safe.code.length > 0, string.concat(name, " has no code: is it deployed on this chain?"));
        uint256 threshold;
        try ISafe(safe).getThreshold() returns (uint256 t) {
            threshold = t;
        } catch {
            revert(string.concat(name, " does not answer getThreshold(): is it a Safe?"));
        }
        require(
            threshold >= minThreshold,
            string.concat(name, " needs at least ", vm.toString(minThreshold), " signers to execute")
        );
    }

    function _isRoleContract(Stack memory s, address target) internal pure returns (bool) {
        return target == address(s.storageV2) || target == address(s.canvas) || target == address(s.market)
            || target == address(s.pool);
    }

    function _expectedRoles(
        Stack memory s,
        Holders memory h,
        address target,
        address who
    ) internal pure returns (uint256) {
        if (who == h.operationsSafe) return target == address(s.storageV2) ? GUARDIAN : GUARDIAN | CONFIG;
        if (who == h.poster && target == address(s.pool)) return POSTER;
        return 0;
    }

    function _contains(address[] memory list, address who) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == who) return true;
        }
        return false;
    }

    function _sameSet(address[] memory a, address[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i; i < a.length; ++i) {
            if (!_contains(b, a[i])) return false;
        }
        return true;
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
        s.normies = vm.envOr("NORMIES_ADDRESS", address(0));
    }

    /// @dev Every role, mover and writer event on the four role contracts since `fromBlock`, in chain order per
    ///      contract. The RPC must serve eth_getLogs over that range.
    function _roleLogs(Stack memory s, uint256 fromBlock) internal returns (VmSafe.Log[] memory out) {
        address[6] memory targets = [
            address(s.storageV2),
            address(s.storageV2),
            address(s.storageV2),
            address(s.canvas),
            address(s.market),
            address(s.pool)
        ];
        bytes32[6] memory sigs = [
            OwnableRoles.RolesUpdated.selector,
            NormiesCanvasStorageV2.MoverRolesSet.selector,
            NormiesCanvasStorageV2.AuthorizedWriterSet.selector,
            OwnableRoles.RolesUpdated.selector,
            OwnableRoles.RolesUpdated.selector,
            OwnableRoles.RolesUpdated.selector
        ];
        VmSafe.EthGetLogs[][6] memory found;
        uint256 total;
        for (uint256 i; i < 6; ++i) {
            bytes32[] memory topics = new bytes32[](1);
            topics[0] = sigs[i];
            found[i] = vm.eth_getLogs(fromBlock, block.number, targets[i], topics);
            total += found[i].length;
        }
        out = new VmSafe.Log[](total);
        uint256 n;
        for (uint256 i; i < 6; ++i) {
            for (uint256 j; j < found[i].length; ++j) {
                out[n++] = VmSafe.Log(found[i][j].topics, found[i][j].data, found[i][j].emitter);
            }
        }
    }
}

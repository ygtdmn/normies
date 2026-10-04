// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "./PixelMarketBase.t.sol";
import { HandoffOwnership } from "../script/HandoffOwnership.s.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { NormiesRoyaltySplitter } from "../src/NormiesRoyaltySplitter.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { VmSafe } from "forge-std/src/Vm.sol";

/// @notice Stands in for a Safe: it has code, signers and a threshold, and sends whatever call its signers agreed on.
contract SafeStub {
    address[] internal owners;
    uint256 public getThreshold;

    constructor(address[] memory _owners, uint256 _threshold) {
        owners = _owners;
        getThreshold = _threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

contract HandoffOwnershipTest is PixelMarketBase {
    HandoffOwnership handoff;
    SafeStub adminSafe;
    SafeStub treasurySafe;
    SafeStub operationsSafe;
    address poster = address(0x9057);
    NormiesRevenuePool pool;
    NormiesRoyaltySplitter splitter;

    function setUp() public override {
        // Every role, mover and writer event from the deployment on, for checkHistory.
        vm.recordLogs();
        super.setUp();
        pool = new NormiesRevenuePool(IWETH(address(new MockWETH())));
        splitter = new NormiesRoyaltySplitter(IWETH(address(0xE7)), address(pool), feeTreasury);
        market.setFeeRecipients(feeTreasury, address(pool));
        // The base gives the test contract a mover role for funding; the real deployer never keeps one.
        storageV2.setMoverRoles(address(this), 0);
        canvas.setPaused(true);
        market.setPaused(true);
        handoff = new HandoffOwnership();
        adminSafe = _safe(0xA0, 5, 3);
        treasurySafe = _safe(0xB0, 3, 2);
        operationsSafe = _safe(0xC0, 3, 2);
    }

    /// @dev A Safe of `count` signers starting at address `first`.
    function _safe(uint160 first, uint160 count, uint256 threshold) internal returns (SafeStub) {
        address[] memory signers = new address[](count);
        for (uint160 i; i < count; ++i) {
            signers[i] = address(first + i);
        }
        return new SafeStub(signers, threshold);
    }

    function _stack() internal view returns (HandoffOwnership.Stack memory) {
        return HandoffOwnership.Stack(storageV2, canvas, market, renderer, pool, splitter, address(0));
    }

    function _logs() internal returns (VmSafe.Log[] memory) {
        return vm.getRecordedLogs();
    }

    function _holders() internal view returns (HandoffOwnership.Holders memory) {
        return HandoffOwnership.Holders(address(adminSafe), address(treasurySafe), address(operationsSafe), poster);
    }

    function _run() internal {
        handoff.handoff(_stack(), _holders(), address(this));
    }

    function testHandoffLeavesTheDeployerWithNothing() public {
        _run();
        handoff.check(_stack(), _holders(), address(this));
        handoff.checkHistory(_stack(), _holders(), new address[](0), _logs());

        assertEq(storageV2.owner(), address(adminSafe));
        assertEq(canvas.owner(), address(adminSafe));
        assertEq(market.owner(), address(adminSafe));
        assertEq(renderer.owner(), address(adminSafe));
        assertEq(pool.owner(), address(treasurySafe));
        assertEq(splitter.owner(), address(treasurySafe));

        uint8 roleCanvas = storageV2.ROLE_CANVAS();
        vm.expectRevert(Ownable.Unauthorized.selector);
        storageV2.setMoverRoles(address(this), roleCanvas);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.withdrawUnallocated(address(this), 0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        market.setFeeRecipients(address(this), address(this));
        vm.expectRevert(Ownable.Unauthorized.selector);
        storageV2.grantRoles(address(this), 1);
        vm.expectRevert(); // Lifebuoy: neither owner nor (locked) deployer
        storageV2.rescueETH(address(this), 0);
    }

    function testGuardianPausesAndUnpausesAtOnceButNeverReachesAdminPowers() public {
        _run();
        // The launch: the guardian unpauses straight away.
        operationsSafe.exec(address(canvas), abi.encodeCall(canvas.setPaused, (false)));
        operationsSafe.exec(address(market), abi.encodeCall(market.setPaused, (false)));
        assertFalse(canvas.paused());
        assertFalse(market.paused());

        // Pausing and resuming everything is immediate too.
        operationsSafe.exec(address(canvas), abi.encodeCall(canvas.setPaused, (true)));
        operationsSafe.exec(address(market), abi.encodeCall(market.setPaused, (true)));
        operationsSafe.exec(address(pool), abi.encodeCall(pool.setPaused, (true)));
        operationsSafe.exec(address(storageV2), abi.encodeCall(storageV2.setAllowancesPaused, (true)));
        assertTrue(canvas.paused() && market.paused() && pool.paused() && storageV2.allowancesPaused());
        operationsSafe.exec(address(canvas), abi.encodeCall(canvas.setPaused, (false)));
        operationsSafe.exec(address(market), abi.encodeCall(market.setPaused, (false)));
        operationsSafe.exec(address(pool), abi.encodeCall(pool.setPaused, (false)));
        operationsSafe.exec(address(storageV2), abi.encodeCall(storageV2.setAllowancesPaused, (false)));
        assertFalse(canvas.paused() || market.paused() || pool.paused() || storageV2.allowancesPaused());

        // Admin powers belong to the owning Safes: the guardian cannot reach them...
        vm.expectRevert(Ownable.Unauthorized.selector);
        operationsSafe.exec(address(market), abi.encodeCall(market.setFeeRecipients, (address(1), address(1))));
        vm.expectRevert(Ownable.Unauthorized.selector);
        operationsSafe.exec(address(storageV2), abi.encodeCall(storageV2.setMoverRoles, (address(1), uint8(1))));
        vm.expectRevert(Ownable.Unauthorized.selector);
        operationsSafe.exec(address(pool), abi.encodeCall(pool.withdrawUnallocated, (address(1), 0)));

        // ...the Admin Safe can, and only over its own contracts.
        adminSafe.exec(address(market), abi.encodeCall(market.setFeeRecipients, (feeTreasury, address(pool))));
        vm.expectRevert(Ownable.Unauthorized.selector);
        adminSafe.exec(address(pool), abi.encodeCall(pool.withdrawUnallocated, (address(1), 0)));

        // CONFIG works within the bounds in code.
        operationsSafe.exec(address(market), abi.encodeCall(market.setFeeConfig, (500, 5000)));
        assertEq(market.feeBps(), 500);
        vm.expectRevert();
        operationsSafe.exec(address(pool), abi.encodeCall(pool.setClaimWindow, (uint64(1 hours))));
    }

    function testRerunIsIdempotentAndCheckCatchesMissingPieces() public {
        _run();
        // A second run changes nothing and still verifies.
        _run();
        handoff.check(_stack(), _holders(), address(this));

        // Checking against a Safe that does not own the stack fails.
        HandoffOwnership.Holders memory wrong = _holders();
        wrong.adminSafe = address(_safe(0xD0, 5, 3));
        vm.expectRevert("storage V2 is not owned by the Admin Safe");
        handoff.check(_stack(), wrong, address(this));
    }

    function testRefusesWrongHoldersBeforeSendingAnything() public {
        HandoffOwnership.Holders memory h = _holders();
        h.operationsSafe = address(adminSafe);
        vm.expectRevert("the Operations Safe must differ from Admin and Treasury");
        handoff.handoff(_stack(), h, address(this));

        h = _holders();
        h.poster = address(this);
        vm.expectRevert("REVSHARE_POSTER must be its own gas-only key");
        handoff.handoff(_stack(), h, address(this));

        h = _holders();
        h.adminSafe = address(0xA11CE);
        vm.expectRevert("ADMIN_SAFE has no code: is it deployed on this chain?");
        handoff.handoff(_stack(), h, address(this));

        h = _holders();
        h.treasurySafe = address(market); // code, but not a Safe
        vm.expectRevert("TREASURY_SAFE does not answer getThreshold(): is it a Safe?");
        handoff.handoff(_stack(), h, address(this));

        storageV2.setMoverRoles(address(this), storageV2.ROLE_WRAPPER());
        vm.expectRevert("the deployer still holds a mover role on storage V2");
        handoff.handoff(_stack(), _holders(), address(this));
        assertEq(storageV2.owner(), address(this));
    }

    function testOneSafeCanOwnTheWholeStack() public {
        // The launch layout: the Admin Safe also owns the pool and the splitter.
        HandoffOwnership.Holders memory h = _holders();
        h.treasurySafe = h.adminSafe;
        handoff.handoff(_stack(), h, address(this));
        handoff.check(_stack(), h, address(this));
        handoff.checkHistory(_stack(), h, new address[](0), _logs());
        assertEq(pool.owner(), address(adminSafe));
        assertEq(splitter.owner(), address(adminSafe));
        adminSafe.exec(address(pool), abi.encodeCall(pool.withdrawUnallocated, (address(adminSafe), 0)));

        // The guardian still has to be its own Safe.
        h.operationsSafe = h.adminSafe;
        vm.expectRevert("the Operations Safe must differ from Admin and Treasury");
        handoff.check(_stack(), h, address(this));
    }

    function testRefusesSafesThatAreNotRealMultisigs() public {
        HandoffOwnership.Holders memory h = _holders();
        h.adminSafe = address(_safe(0xA0, 5, 2));
        vm.expectRevert("ADMIN_SAFE needs at least 3 signers to execute");
        handoff.handoff(_stack(), h, address(this));

        h = _holders();
        h.operationsSafe = address(_safe(0xC0, 1, 1));
        vm.expectRevert("OPERATIONS_SAFE needs at least 2 signers to execute");
        handoff.handoff(_stack(), h, address(this));

        h = _holders();
        h.treasurySafe = address(_safe(0xC0, 3, 2)); // the Operations Safe's signers again
        vm.expectRevert("the Treasury and Operations Safes have the same signers");
        handoff.handoff(_stack(), h, address(this));

        h = _holders();
        h.poster = address(0xA2); // one of the Admin Safe's signers
        vm.expectRevert("REVSHARE_POSTER is a Safe signer; it lives on the API host and must sign nothing");
        handoff.handoff(_stack(), h, address(this));

        // The same holders pass the read-only check too, so a Safe changed after the handoff is caught.
        _run();
        h = _holders();
        h.adminSafe = address(_safe(0xA0, 5, 1));
        vm.expectRevert("ADMIN_SAFE needs at least 3 signers to execute");
        handoff.check(_stack(), h, address(this));
    }

    function testHistoryCatchesARoleOutsideTheLayout() public {
        canvas.grantRoles(address(0xBAD), 2); // CONFIG to a stranger, while the deployer still owns canvas V2
        _run();
        handoff.check(_stack(), _holders(), address(this)); // the current-state check cannot see it...
        VmSafe.Log[] memory logs = _logs();
        vm.expectRevert(
            bytes(
                string.concat(
                    "unexpected roles on ", vm.toString(address(canvas)), " for ", vm.toString(address(0xBAD))
                )
            )
        );
        handoff.checkHistory(_stack(), _holders(), new address[](0), logs); // ...the replay does
    }

    function testHistoryCatchesAStrayMover() public {
        storageV2.setMoverRoles(address(0x3A9), storageV2.ROLE_WRAPPER());
        _run();
        VmSafe.Log[] memory logs = _logs();
        vm.expectRevert(bytes(string.concat("unexpected mover role for ", vm.toString(address(0x3A9)))));
        handoff.checkHistory(_stack(), _holders(), new address[](0), logs);
    }

    function testHistoryAcceptsOnlyTheListedWriters() public {
        address bot = address(0xB07);
        storageV2.setAuthorizedWriter(bot, true);
        _run();
        VmSafe.Log[] memory logs = _logs();
        vm.expectRevert(bytes(string.concat("unexpected overlay writer ", vm.toString(bot))));
        handoff.checkHistory(_stack(), _holders(), new address[](0), logs);

        address[] memory writers = new address[](1);
        writers[0] = bot;
        handoff.checkHistory(_stack(), _holders(), writers, logs);

        // A listed writer that was removed is reported as missing.
        adminSafe.exec(address(storageV2), abi.encodeCall(storageV2.setAuthorizedWriter, (bot, false)));
        vm.expectRevert(bytes(string.concat("missing overlay writer ", vm.toString(bot))));
        handoff.checkHistory(_stack(), _holders(), writers, logs);
    }

    function testHistoryNeedsTheDeploymentEvents() public {
        _run();
        vm.expectRevert("no role events found: is DEPLOY_BLOCK at or before the deployment?");
        handoff.checkHistory(_stack(), _holders(), new address[](0), new VmSafe.Log[](0));
    }

    function testNormiesMustSitWithTheAdminSafeWithRescueLocked() public {
        _run();
        HandoffOwnership.Stack memory s = _stack();
        s.normies = address(normies);
        vm.expectRevert("the Normies NFT is not owned by the Admin Safe");
        handoff.check(s, _holders(), address(this));

        // Moving it without locking the deployer's rescue access first is not enough.
        normies.transferOwnership(address(adminSafe));
        vm.expectRevert("Normies: the deployer's rescue access is not locked");
        handoff.check(s, _holders(), address(this));

        adminSafe.exec(address(normies), abi.encodeCall(normies.lockRescue, (1)));
        handoff.check(s, _holders(), address(this));
    }

    function testPosterPostsAndTheGuardianCancelsBeforeClaimsOpen() public {
        _run();
        vm.deal(address(pool), 1 ether);
        vm.roll(block.number + 100);
        vm.prank(poster);
        uint256 id = pool.postEpoch(keccak256("root"), 1 ether, 1, 10, bytes32(0), "");
        assertEq(pool.unallocated(), 0);
        vm.prank(address(operationsSafe));
        pool.cancelEpoch(id);
        assertEq(pool.unallocated(), 1 ether);
        // The poster can do nothing else.
        vm.prank(poster);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.withdrawUnallocated(poster, 1);
    }
}

contract HandoffOwnershipPreCutoverTest is PixelMarketBase {
    function setUp() public override {
        cutoverInSetUp = false;
        super.setUp();
    }

    function testRefusesBeforeTheMigrationIsFinal() public {
        HandoffOwnership handoff = new HandoffOwnership();
        HandoffOwnership.Stack memory s;
        s.storageV2 = storageV2;
        address[] memory a = new address[](3);
        a[0] = address(0xA0);
        a[1] = address(0xA1);
        a[2] = address(0xA2);
        address[] memory b = new address[](2);
        b[0] = address(0xB0);
        b[1] = address(0xB1);
        address[] memory c = new address[](2);
        c[0] = address(0xC0);
        c[1] = address(0xC1);
        HandoffOwnership.Holders memory h = HandoffOwnership.Holders(
            address(new SafeStub(a, 3)), address(new SafeStub(b, 2)), address(new SafeStub(c, 2)), address(0x9057)
        );
        vm.expectRevert("finalize the balance migration first (MigrateLegacy.s.sol)");
        handoff.handoff(s, h, address(this));
    }
}

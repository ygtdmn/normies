// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "./PixelMarketBase.t.sol";
import { HandoffOwnership } from "../script/HandoffOwnership.s.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { NormiesRoyaltySplitter } from "../src/NormiesRoyaltySplitter.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice Stands in for a Safe: it has code and sends whatever call its signers agreed on.
contract SafeStub {
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
        super.setUp();
        pool = new NormiesRevenuePool(IWETH(address(new MockWETH())));
        splitter = new NormiesRoyaltySplitter(IWETH(address(0xE7)), address(pool), feeTreasury);
        market.setFeeRecipients(feeTreasury, address(pool));
        // The base gives the test contract a mover role for funding; the real deployer never keeps one.
        storageV2.setMoverRoles(address(this), 0);
        canvas.setPaused(true);
        market.setPaused(true);
        handoff = new HandoffOwnership();
        adminSafe = new SafeStub();
        treasurySafe = new SafeStub();
        operationsSafe = new SafeStub();
    }

    function _stack() internal view returns (HandoffOwnership.Stack memory) {
        return HandoffOwnership.Stack(storageV2, canvas, market, renderer, pool, splitter);
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
        wrong.adminSafe = address(new SafeStub());
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

        storageV2.setMoverRoles(address(this), storageV2.ROLE_WRAPPER());
        vm.expectRevert("the deployer still holds a mover role on storage V2");
        handoff.handoff(_stack(), _holders(), address(this));
        assertEq(storageV2.owner(), address(this));
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
        HandoffOwnership.Holders memory h = HandoffOwnership.Holders(
            address(new SafeStub()), address(new SafeStub()), address(new SafeStub()), address(0x9057)
        );
        vm.expectRevert("finalize the balance migration first (MigrateLegacy.s.sol)");
        handoff.handoff(s, h, address(this));
    }
}

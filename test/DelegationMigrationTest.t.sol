// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { PixelMarketBase } from "./PixelMarketBase.t.sol";
import { NormiesCanvas } from "../src/NormiesCanvas.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvasV1 } from "../src/interfaces/INormiesCanvasV1.sol";

/// @dev The snapshot the TypeScript migration (api-server/src/cutover/migrate-delegations.ts) takes, in Solidity,
///      so the copy-and-seal path can be exercised in-process. Same prerequisites and messages as the script.
contract DelegationSnapshot {
    uint256 public constant TOKEN_COUNT = 10_000;

    struct Snapshot {
        uint256 blockNumber;
        uint256 timestamp;
        uint256[] tokenIds;
        address[] delegates;
        address[] setBy;
    }

    function snapshot(NormiesCanvasStorageV2 v2) public view returns (Snapshot memory s) {
        require(!v2.delegationsSeeded(), "delegations already finalized");
        require(v2.migrationFinalized(), "finalize the balance migration first");
        NormiesCanvas v1 = NormiesCanvas(address(v2.legacyCanvas()));
        require(v1.paused(), "pause the original canvas before migration");
        s.blockNumber = block.number;
        s.timestamp = block.timestamp;
        uint256[] memory ids = new uint256[](TOKEN_COUNT);
        address[] memory ds = new address[](TOKEN_COUNT);
        address[] memory owners = new address[](TOKEN_COUNT);
        uint256 n;
        for (uint256 id; id < TOKEN_COUNT; id++) {
            address d = v1.delegates(id);
            if (d == address(0)) continue;
            ids[n] = id;
            ds[n] = d;
            owners[n] = v1.delegateSetBy(id);
            n++;
        }
        s.tokenIds = new uint256[](n);
        s.delegates = new address[](n);
        s.setBy = new address[](n);
        for (uint256 i; i < n; i++) {
            s.tokenIds[i] = ids[i];
            s.delegates[i] = ds[i];
            s.setBy[i] = owners[i];
        }
    }
}

contract DelegationMigrationTest is PixelMarketBase {
    DelegationSnapshot script;

    function setUp() public override {
        cutoverInSetUp = false;
        super.setUp();
        vm.roll(100);
        vm.warp(1_800_000_000);
        _mintRealTo(user, 1);
        _mintRealTo(buyer, 9999);
        script = new DelegationSnapshot();
    }

    function _snapshot() internal returns (DelegationSnapshot.Snapshot memory) {
        storageV2.finalizeMigration();
        return script.snapshot(storageV2);
    }

    function _apply(DelegationSnapshot.Snapshot memory s) internal {
        storageV2.seedAndFinalizeDelegations(s.tokenIds, s.delegates, s.setBy, s.blockNumber, s.timestamp);
    }

    function testFullSnapshotPreservesLiveAndStaleDelegatesIncludingLastId() public {
        vm.prank(user);
        canvasV1.setDelegate(1, delegate_);
        vm.prank(buyer);
        canvasV1.setDelegate(9999, hotWallet);
        vm.prank(buyer);
        normies.transferFrom(buyer, user, 9999);
        DelegationSnapshot.Snapshot memory s = _snapshot();
        assertEq(s.tokenIds.length, 2);
        assertEq(s.tokenIds[0], 1);
        assertEq(s.tokenIds[1], 9999);
        assertEq(s.setBy[1], buyer);
        _apply(s);
        assertTrue(storageV2.delegationsSeeded());
        assertEq(storageV2.delegates(1), delegate_);
        assertEq(storageV2.delegates(9999), hotWallet);
        assertEq(storageV2.delegateSetBy(9999), buyer);
        assertEq(storageV2.delegationSnapshotBlock(), 100);
        assertEq(storageV2.delegationSnapshotTimestamp(), 1_800_000_000);
    }

    function testSnapshotBoundaryIgnoresLaterV1ChangesBeforeAndAfterInclusion() public {
        vm.prank(user);
        canvasV1.setDelegate(1, delegate_);
        DelegationSnapshot.Snapshot memory s = _snapshot();
        vm.roll(101);
        vm.warp(block.timestamp + 12);
        vm.prank(user);
        canvasV1.revokeDelegate(1);
        vm.prank(buyer);
        canvasV1.setDelegate(9999, hotWallet);
        _apply(s);
        assertEq(storageV2.delegates(1), delegate_);
        assertEq(storageV2.delegates(9999), address(0));
        vm.prank(user);
        canvasV1.setDelegate(1, unauthorized);
        assertEq(storageV2.delegates(1), delegate_);
        // Once sealed, all changes happen on V2, even before painting is unpaused.
        vm.prank(user);
        canvas.revokeDelegate(1);
        assertEq(storageV2.delegates(1), address(0));
        vm.expectRevert(NormiesCanvasStorageV2.DelegationsSealed.selector);
        _apply(s);
        assertEq(storageV2.delegates(1), address(0));
    }

    function testV2DelegationEditsCannotRaceTheSnapshot() public {
        vm.prank(user);
        vm.expectRevert(NormiesCanvasStorageV2.DelegationsNotFinalized.selector);
        canvas.setDelegate(1, delegate_);
        vm.prank(user);
        vm.expectRevert(NormiesCanvasStorageV2.DelegationsNotFinalized.selector);
        canvas.revokeDelegate(1);
        _apply(_snapshot());
        vm.prank(user);
        canvas.setDelegate(1, delegate_);
        vm.prank(user);
        canvas.revokeDelegate(1);
        assertEq(storageV2.delegates(1), address(0));
    }

    function testEmptySnapshotStillSealsInOneCall() public {
        DelegationSnapshot.Snapshot memory s = _snapshot();
        assertEq(s.tokenIds.length, 0);
        _apply(s);
        assertTrue(storageV2.delegationsSeeded());
        vm.expectRevert(NormiesCanvasStorageV2.DelegationsSealed.selector);
        _apply(s);
        vm.expectRevert("delegations already finalized");
        script.snapshot(storageV2);
    }

    function testSnapshotRequiresPausedLegacyAndFinalizedBalances() public {
        vm.expectRevert("finalize the balance migration first");
        script.snapshot(storageV2);
        storageV2.finalizeMigration();
        canvasV1.setPaused(false);
        vm.expectRevert("pause the original canvas before migration");
        script.snapshot(storageV2);
    }

    function testAtomicEntryPointChecksOwnerPrerequisitesAndSnapshotBounds() public {
        uint256[] memory ids = new uint256[](0);
        address[] memory ds = new address[](0);
        vm.prank(unauthorized);
        vm.expectRevert("Ownable: caller is not the owner");
        storageV2.seedAndFinalizeDelegations(ids, ds, ds, 100, block.timestamp);
        vm.expectRevert(NormiesCanvasStorageV2.MigrationNotFinalized.selector);
        storageV2.seedAndFinalizeDelegations(ids, ds, ds, 100, block.timestamp);
        storageV2.finalizeMigration();
        canvasV1.setPaused(false);
        vm.expectRevert(NormiesCanvasStorageV2.LegacyCanvasNotPaused.selector);
        storageV2.seedAndFinalizeDelegations(ids, ds, ds, 100, block.timestamp);
        canvasV1.setPaused(true);
        vm.expectRevert(NormiesCanvasStorageV2.InvalidSnapshot.selector);
        storageV2.seedAndFinalizeDelegations(ids, ds, ds, 101, block.timestamp);
        vm.expectRevert(NormiesCanvasStorageV2.InvalidSnapshot.selector);
        storageV2.seedAndFinalizeDelegations(ids, ds, ds, 100, block.timestamp + 1);
        assertFalse(storageV2.delegationsSeeded());
    }

    function testOutOfGasRollsBackEverySeedAndLeavesMigrationOpen() public {
        storageV2.finalizeMigration();
        uint256[] memory ids = new uint256[](4);
        address[] memory ds = new address[](4);
        address[] memory owners = new address[](4);
        for (uint256 i; i < 4; i++) {
            ids[i] = i + 1;
            ds[i] = delegate_;
            owners[i] = user;
        }
        bytes memory data =
            abi.encodeCall(storageV2.seedAndFinalizeDelegations, (ids, ds, owners, block.number, block.timestamp));
        (bool ok,) = address(storageV2).call{ gas: 100_000 }(data);
        assertFalse(ok);
        assertFalse(storageV2.delegationsSeeded());
        assertEq(storageV2.delegationSnapshotBlock(), 0);
        for (uint256 i; i < 4; i++) {
            assertEq(storageV2.delegates(i + 1), address(0));
        }
        // A fresh full transaction succeeds: even the "started" flag was rolled back.
        storageV2.seedAndFinalizeDelegations(ids, ds, owners, block.number, block.timestamp);
        assertTrue(storageV2.delegationsSeeded());
    }

    function testMalformedSnapshotDoesNotWriteOrSeal() public {
        uint256[] memory ids = new uint256[](1);
        address[] memory ds = new address[](0);
        storageV2.finalizeMigration();
        vm.expectRevert(NormiesCanvasStorageV2.LengthMismatch.selector);
        storageV2.seedAndFinalizeDelegations(ids, ds, ds, block.number, block.timestamp);
        assertFalse(storageV2.delegationsSeeded());
        assertEq(storageV2.delegationSnapshotBlock(), 0);
    }
}

contract DelegationMigrationForkTest is Test {
    function testForkFullSnapshotAndAtomicMigrationFitsTransactionBudget() public {
        if (bytes(vm.envOr("API_KEY_ALCHEMY", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", 25_999_628);
        NormiesCanvas v1 = NormiesCanvas(0x64951d92e345C50381267380e2975f66810E869c);
        NormiesCanvasStorageV2 v2 = new NormiesCanvasStorageV2(
            INormiesCanvasStorage(0xC255BE0983776BAB027a156681b6925cde47B2D1), INormiesCanvasV1(address(v1))
        );
        vm.prank(v1.owner());
        v1.setPaused(true);
        // This fixture tests delegation migration after the independent balance stage.
        v2.finalizeMigration();
        DelegationSnapshot script = new DelegationSnapshot();
        DelegationSnapshot.Snapshot memory s = script.snapshot(v2);
        uint256 beforeGas = gasleft();
        v2.seedAndFinalizeDelegations(s.tokenIds, s.delegates, s.setBy, s.blockNumber, s.timestamp);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("snapshot delegation count", s.tokenIds.length);
        emit log_named_uint("atomic copy-and-seal execution gas", used);
        // Conservative room for calldata, intrinsic gas, and initially cold accesses.
        assertLt(used + s.tokenIds.length * 2000 + 100_000, 16_777_216);
        assertTrue(v2.delegationsSeeded());
        assertEq(v2.delegationSnapshotBlock(), 25_999_628);
        for (uint256 i; i < s.tokenIds.length; i++) {
            assertEq(v2.delegates(s.tokenIds[i]), s.delegates[i]);
            assertEq(v2.delegateSetBy(s.tokenIds[i]), s.setBy[i]);
        }
    }
}

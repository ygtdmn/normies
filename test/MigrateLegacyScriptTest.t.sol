// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "./PixelMarketBase.t.sol";
import { MigrateLegacy } from "../script/MigrateLegacy.s.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";

/// @notice Runs the real cutover script against the test stack (audit C-M4): the finalize gate and the full scan.
contract MigrateLegacyScriptTest is PixelMarketBase {
    function setUp() public override {
        cutoverInSetUp = false;
        super.setUp();
        // The script broadcasts from the default sender, which plays the storage owner here.
        storageV2.transferOwnership(DEFAULT_SENDER);
        vm.setEnv("CANVAS_STORAGE_V2_ADDRESS", vm.toString(address(storageV2)));
    }

    function testScriptGatesFinalizeOnTheOriginalTotalAndScansEveryIdOnMainnet() public {
        uint256 a = _earnOnV1(user, 3, 48);
        uint256 b = _earnOnV1(user, 7, 48);
        MigrateLegacy script = new MigrateLegacy();

        // Mainnet: no shortened scans.
        vm.chainId(1);
        vm.setEnv("TOKEN_IDS", "3,7");
        vm.expectRevert("TOKEN_IDS is for local forks only: mainnet scans every id (audit C-M4)");
        script.run();
        vm.setEnv("TOKEN_IDS", "");
        vm.setEnv("MAX_TOKEN_ID", "100");
        vm.expectRevert("MAX_TOKEN_ID must cover every id (9999) on mainnet (audit C-M4)");
        script.run();

        // A local fork may pass a list. A list that misses a balance cannot be sealed: the gate is the V1 total of
        // the list, and storage V2 also checks it holds exactly that.
        vm.chainId(31_337);
        vm.setEnv("MAX_TOKEN_ID", "9999");
        vm.setEnv("TOKEN_IDS", "3,7");
        script.run();
        assertTrue(storageV2.migrationFinalized());
        assertEq(storageV2.totalAttached(), a + b);
        assertEq(storageV2.attachedOf(3), a);
        assertEq(storageV2.attachedOf(7), b);
        vm.setEnv("TOKEN_IDS", "");
    }

    function testStorageRefusesASealThatDoesNotMatch() public {
        uint256 a = _earnOnV1(user, 3, 48);
        uint256 b = _earnOnV1(user, 7, 48);
        storageV2.migrateBatch(_one(3)); // token 7 forgotten
        vm.prank(DEFAULT_SENDER);
        vm.expectRevert(abi.encodeWithSelector(NormiesCanvasStorageV2.MigrationTotalMismatch.selector, a + b, a));
        storageV2.finalizeMigration(a + b);
        assertFalse(storageV2.migrationFinalized());
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}

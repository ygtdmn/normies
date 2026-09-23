// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script, console } from "forge-std/src/Script.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { NormiesCanvas } from "../src/NormiesCanvas.sol";

/**
 * @notice Copies every nonzero balance from the original canvas into NormiesCanvasStorageV2 and closes the migration.
 *         Refuses while any burn on the original canvas is still unrevealed (its reward would be lost), and pauses
 *         that canvas first if it is not paused yet (the broadcaster must own it); rerun after that pause lands.
 *         Reads the original canvas through the storage's own `legacyCanvas`, so there is no list to get wrong:
 *         the scan covers token ids 0..MAX_TOKEN_ID and the storage reads each balance itself on chain.
 *         Run once, right after the original canvas is paused, from the storage owner. Idempotent: tokens already
 *         copied are skipped, and FINALIZE=false leaves the migration open for another pass.
 *
 * Env: CANVAS_STORAGE_V2_ADDRESS; optional MAX_TOKEN_ID (9999), BATCH (150), FINALIZE (true), and TOKEN_IDS, a
 *      comma-separated candidate list (for example every receiver of a V1 BurnRevealed event) that replaces the
 *      full scan; each candidate is still read from V1 on chain, so a wrong list can only miss tokens, never
 *      invent balances.
 */
contract MigrateLegacy is Script {
    function run() public {
        NormiesCanvasStorageV2 pixels = NormiesCanvasStorageV2(vm.envAddress("CANVAS_STORAGE_V2_ADDRESS"));
        uint256 maxId = vm.envOr("MAX_TOKEN_ID", uint256(9999));
        uint256 batch = vm.envOr("BATCH", uint256(150));
        bool finalize = vm.envOr("FINALIZE", true);
        NormiesCanvas v1 = NormiesCanvas(address(pixels.legacyCanvas()));

        require(!pixels.migrationFinalized(), "migration already finalized");
        uint256 commits = v1.nextCommitId();
        for (uint256 id; id < commits; id++) {
            (,,,, bool revealed,) = v1.burnCommitments(id);
            require(revealed, string.concat("unrevealed V1 burn commitment #", vm.toString(id), ": reveal it first"));
        }
        if (!v1.paused()) {
            console.log("original canvas is not paused: pausing it now, rerun to migrate");
            vm.startBroadcast();
            v1.setPaused(true);
            vm.stopBroadcast();
            return;
        }

        uint256[] memory candidates = vm.envOr("TOKEN_IDS", ",", new uint256[](0));
        if (candidates.length == 0) {
            candidates = new uint256[](maxId + 1);
            for (uint256 id; id <= maxId; id++) {
                candidates[id] = id;
            }
        }
        uint256[] memory pending = new uint256[](candidates.length);
        uint256 n;
        uint256 total;
        for (uint256 c; c < candidates.length; c++) {
            uint256 id = candidates[c];
            if (pixels.migrated(id)) continue;
            uint256 legacy = pixels.legacyCanvas().actionPoints(id);
            if (legacy == 0) continue;
            pending[n++] = id;
            total += legacy;
        }
        console.log("tokens to migrate:", n, "pixels:", total);

        vm.startBroadcast();
        for (uint256 start; start < n; start += batch) {
            uint256 len = n - start < batch ? n - start : batch;
            uint256[] memory ids = new uint256[](len);
            for (uint256 i; i < len; i++) {
                ids[i] = pending[start + i];
            }
            pixels.migrateBatch(ids);
        }
        if (finalize) pixels.finalizeMigration();
        vm.stopBroadcast();

        console.log("storage totalAttached:", pixels.totalAttached(), "finalized:", pixels.migrationFinalized());
    }
}

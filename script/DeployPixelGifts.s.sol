// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesPixelGifts } from "../src/NormiesPixelGifts.sol";

/**
 * @title DeployPixelGifts
 * @notice Deploys NormiesPixelGifts, owned by PIXEL_GIFTS_ADMIN. The broadcaster grants nothing and locks its own
 *         Lifebuoy rescue access (lockRescue(1)). Nothing can be given until the admin wires it; see
 *         PixelGiftsRunbook.md and script/pixel-gifts-safe.sh:
 *           1. pixel ledger:   setMoverRoles(gifts, 1)
 *           2. Arena storage:  setAuthorizedWriter(gifts, true)
 *           3. gifts:          grantRoles(gifter wallet, 32)
 *
 *         Environment:
 *           ARENA_STORAGE      the NormiesArenaStorage to credit (the pixel ledger is read from it)
 *           PIXEL_GIFTS_ADMIN  owner of the contract (the Safe that owns the ledger and the Arena storage)
 */
contract DeployPixelGifts is Script {
    /// @dev Lifebuoy's flag that locks the deployer's rescue access.
    uint256 internal constant DEPLOYER_RESCUE_LOCK = 1;

    function run() external returns (NormiesPixelGifts gifts) {
        address store = vm.envAddress("ARENA_STORAGE");
        address admin = vm.envAddress("PIXEL_GIFTS_ADMIN");
        vm.startBroadcast();
        gifts = new NormiesPixelGifts(store, admin);
        gifts.lockRescue(DEPLOYER_RESCUE_LOCK);
        vm.stopBroadcast();
    }
}

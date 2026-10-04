// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { NormiesZombie } from "../src/NormiesZombie.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { NormiesCanvasV2 } from "../src/NormiesCanvasV2.sol";
import { NormiesPixelMarket } from "../src/NormiesPixelMarket.sol";
import { NormiesRendererV6 } from "../src/NormiesRendererV6.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { NormiesRoyaltySplitter } from "../src/NormiesRoyaltySplitter.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { INormiesCanvasStorage } from "../src/interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvasStorageV2 } from "../src/interfaces/INormiesCanvasStorageV2.sol";
import { INormiesCanvasV1 } from "../src/interfaces/INormiesCanvasV1.sol";
import { INormiesZombie } from "../src/interfaces/INormiesZombie.sol";
import { INormiesLegendaryCanvas } from "../src/interfaces/INormiesLegendaryCanvas.sol";

/**
 * @notice Deploys the Pixel Market stack (storage V2 with the pixel accounting, canvas V2, market, renderer V6)
 *         and the revenue share (pool + royalty splitter), and wires them. Deliberately left out of this script:
 *         - pausing the V1 canvas (do it first, from the V1 owner, once every V1 commitment is revealed),
 *         - copying the V1 balances in: MigrateLegacy.s.sol, right after this one,
 *         - normies.setRendererContract(rendererV6),
 *         - normies.setRoyaltyInfo(royaltySplitter, 500) and the OpenSea creator earnings payout address,
 *         - unpausing CanvasV2 and the market (both start paused and refuse to unpause until the storage
 *           migration and the delegation copy are finalized).
 *         - handing ownership to the owner Safe(s) and the roles to the Operations Safe and the
 *           revshare poster: HandoffOwnership.s.sol, after the cutover and before the unpause (which the
 *           Operations Safe then sends).
 *
 * Env: NORMIES_ADDRESS, STORAGE_ADDRESS, CANVAS_ADDRESS (V1), CANVAS_STORAGE_ADDRESS (V1),
 *      FEE_TREASURY, ROYALTY_TEAM (the team's half of royalties);
 *      ZOMBIE_ADDRESS, LEGENDARY_CANVAS_ADDRESS; optional WETH_ADDRESS (mainnet WETH9 by default),
 *      EXTRA_STORAGE_WRITER.
 */
contract DeployPixelMarket is Script {
    // The completed campaign is retained as-is. Never deploy a replacement converter or zombie storage.
    address public constant EXISTING_ZOMBIE = 0x18533ad55a54c3847Da06A48b51aD7DcB2551202;
    address public constant EXISTING_ZOMBIE_STORAGE = 0xA331bD22C90D1DA096934Db8bc6b69F0e1491E26;

    struct Env {
        address normies;
        address originalStorage;
        address canvasV1;
        address canvasStorageV1;
        address feeTreasury;
        address royaltyTeam;
        address weth;
        address zombie;
        address legendaryCanvas;
        address extraWriter;
    }

    struct Deployed {
        NormiesCanvasStorageV2 storageV2;
        NormiesCanvasV2 canvasV2;
        NormiesPixelMarket market;
        NormiesRendererV6 rendererV6;
        NormiesRevenuePool revenuePool;
        NormiesRoyaltySplitter royaltySplitter;
    }

    function run() public returns (Deployed memory d) {
        Env memory env = _env();
        validateZombieCampaign(env.zombie, env.normies);

        vm.startBroadcast();

        // 1. Storage V2: overlays (falling back to V1 storage) and the pixel accounting.
        d.storageV2 =
            new NormiesCanvasStorageV2(INormiesCanvasStorage(env.canvasStorageV1), INormiesCanvasV1(env.canvasV1));

        // 2. Canvas V2.
        d.canvasV2 = new NormiesCanvasV2(
            env.normies, INormiesStorage(env.originalStorage), INormiesCanvasStorageV2(address(d.storageV2))
        );

        // 3. Market.
        d.market = new NormiesPixelMarket(INormiesCanvasStorageV2(address(d.storageV2)));

        // 4. Renderer V6.
        d.rendererV6 =
            new NormiesRendererV6(INormiesStorage(env.originalStorage), INormiesCanvasStorageV2(address(d.storageV2)));

        // 5. Revenue share: the pool takes the holders' half of market fees, the splitter feeds it royalties.
        d.revenuePool = new NormiesRevenuePool(IWETH(env.weth));
        d.royaltySplitter = new NormiesRoyaltySplitter(IWETH(env.weth), address(d.revenuePool), env.royaltyTeam);

        // 6. Wiring.
        _wire(d, env);

        vm.stopBroadcast();
    }

    /// @notice Read-only preflight, before any broadcast: retain the existing completed 21-claim campaign.
    /// @dev Does not pause, reauthorize, reseed, change a root, or write any zombie data.
    function validateZombieCampaign(address zombieAddress, address normiesAddress) public view {
        require(zombieAddress == EXISTING_ZOMBIE, "retain the existing zombie contract");
        NormiesZombie zombie = NormiesZombie(zombieAddress);
        require(address(zombie.normies()) == normiesAddress, "zombie collection mismatch");
        require(address(zombie.zombieStorage()) == EXISTING_ZOMBIE_STORAGE, "retain the existing zombie storage");
        require(zombie.CLAIM_COUNT() == 21 && zombie.seedLocked(), "zombie campaign not initialized");
        require(zombie.zombieStorage().isPoolSealed(), "zombie pool not sealed");

        uint256 claimedSlots;
        uint256 next = zombie.nextCommitId();
        for (uint256 id = 1; id < next; id++) {
            (address wallet,,, uint256 tokenId, uint256 index,, bool revealed, bool cancelled) = zombie.commitments(id);
            require(revealed || cancelled, "pending zombie conversion");
            if (!revealed) continue;
            require(!cancelled && index < 21, "invalid zombie claim");
            uint256 bit = uint256(1) << index;
            require(claimedSlots & bit == 0, "duplicate zombie claim slot");
            claimedSlots |= bit;
            require(zombie.hasClaimed(wallet) && zombie.pendingCommit(wallet) == 0, "zombie claim not settled");
            require(!zombie.tokenLocked(tokenId), "zombie token still locked");
            require(
                zombie.zombieStorage().poolIndexOf(tokenId) == zombie.assignedPoolIndex(index),
                "zombie assignment mismatch"
            );
        }
        require(claimedSlots == (uint256(1) << 21) - 1, "all 21 zombie claims must be completed");
    }

    function _wire(Deployed memory d, Env memory env) internal {
        d.storageV2.setMoverRoles(address(d.canvasV2), d.storageV2.ROLE_CANVAS());
        d.storageV2.setMoverRoles(address(d.market), d.storageV2.ROLE_MARKET());
        d.storageV2.setAuthorizedWriter(address(d.canvasV2), true);
        if (env.extraWriter != address(0)) d.storageV2.setAuthorizedWriter(env.extraWriter, true);
        d.canvasV2.setZombieContract(INormiesZombie(env.zombie));
        d.market.setFeeRecipients(env.feeTreasury, address(d.revenuePool));
        d.rendererV6.setZombieContract(INormiesZombie(env.zombie));
        d.rendererV6.setLegendaryCanvasContract(INormiesLegendaryCanvas(env.legendaryCanvas));
    }

    function _env() internal view returns (Env memory env) {
        env.normies = vm.envAddress("NORMIES_ADDRESS");
        env.originalStorage = vm.envAddress("STORAGE_ADDRESS");
        env.canvasV1 = vm.envAddress("CANVAS_ADDRESS");
        env.canvasStorageV1 = vm.envAddress("CANVAS_STORAGE_ADDRESS");
        env.feeTreasury = vm.envAddress("FEE_TREASURY");
        env.royaltyTeam = vm.envAddress("ROYALTY_TEAM");
        env.weth = vm.envOr("WETH_ADDRESS", 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        env.zombie = vm.envAddress("ZOMBIE_ADDRESS");
        env.legendaryCanvas = vm.envAddress("LEGENDARY_CANVAS_ADDRESS");
        env.extraWriter = vm.envOr("EXTRA_STORAGE_WRITER", address(0));
    }
}

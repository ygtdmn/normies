// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { DeployPixelMarket } from "../script/DeployPixelMarket.s.sol";
import { NormiesZombie } from "../src/NormiesZombie.sol";
import { NormiesZombieStorage } from "../src/NormiesZombieStorage.sol";
import { Normies } from "../src/Normies.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { Base64 } from "solady/utils/Base64.sol";

contract ZombiePreservationTest is Test {
    DeployPixelMarket deployment;
    NormiesZombie constant ZOMBIE = NormiesZombie(0x18533ad55a54c3847Da06A48b51aD7DcB2551202);
    NormiesZombieStorage constant ZOMBIE_STORAGE = NormiesZombieStorage(0xA331bD22C90D1DA096934Db8bc6b69F0e1491E26);
    Normies constant NFT = Normies(0x9Eb6E2025B64f340691e424b7fe7022fFDE12438);

    function setUp() public {
        if (bytes(vm.envOr("API_KEY_ALCHEMY", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", 25_999_628);
        deployment = new DeployPixelMarket();
    }

    function testCompletedCampaignPassesPreflight() public view {
        deployment.validateZombieCampaign(address(ZOMBIE), address(NFT));
    }

    function testRejectsReplacementConverter() public {
        vm.expectRevert("retain the existing zombie contract");
        deployment.validateZombieCampaign(address(0x1234), address(NFT));
    }

    function testRejectsDifferentCollection() public {
        vm.expectRevert("zombie collection mismatch");
        deployment.validateZombieCampaign(address(ZOMBIE), address(0x1234));
    }

    function testRejectsIncompleteCampaign() public {
        vm.mockCall(address(ZOMBIE), abi.encodeWithSelector(ZOMBIE.nextCommitId.selector), abi.encode(uint256(1)));
        vm.expectRevert("all 21 zombie claims must be completed");
        deployment.validateZombieCampaign(address(ZOMBIE), address(NFT));
    }

    function testRejectsPendingConversion() public {
        vm.mockCall(
            address(ZOMBIE),
            abi.encodeWithSelector(ZOMBIE.commitments.selector, uint256(1)),
            abi.encode(address(1), address(1), address(1), uint256(1), uint256(0), uint64(1), false, false)
        );
        vm.expectRevert("pending zombie conversion");
        deployment.validateZombieCampaign(address(ZOMBIE), address(NFT));
    }

    function testCutoverPreservesExactly21ZombieAssignmentsAndArt() public {
        uint256[21] memory ids;
        bytes32[21] memory records;
        uint256 count;
        for (uint256 commitId = 1; commitId < ZOMBIE.nextCommitId(); commitId++) {
            (,,, uint256 id,,, bool revealed,) = ZOMBIE.commitments(commitId);
            if (!revealed) continue;
            require(count < 21, "unexpected extra zombie claim");
            ids[count] = id;
            records[count] = _record(id);
            count++;
        }
        assertEq(count, 21, "exactly the completed campaign");
        bytes32 root = ZOMBIE.merkleRoot();
        bytes32 seed = ZOMBIE.seed();
        uint256 nextCommit = ZOMBIE.nextCommitId();
        bool wasPaused = ZOMBIE.paused();
        bool wasWriter = ZOMBIE_STORAGE.authorizedWriters(address(ZOMBIE));

        vm.setEnv("NORMIES_ADDRESS", vm.toString(address(NFT)));
        vm.setEnv("STORAGE_ADDRESS", "0x1B976bAf51cF51F0e369C070d47FBc47A706e602");
        vm.setEnv("CANVAS_ADDRESS", "0x64951d92e345C50381267380e2975f66810E869c");
        vm.setEnv("CANVAS_STORAGE_ADDRESS", "0xC255BE0983776BAB027a156681b6925cde47B2D1");
        vm.setEnv("ZOMBIE_ADDRESS", vm.toString(address(ZOMBIE)));
        vm.setEnv("LEGENDARY_CANVAS_ADDRESS", "0xfA55f6592522dA74224a67c7D3Fd1DF759c628e8");
        vm.setEnv("FEE_TREASURY", vm.toString(address(0xFEE)));
        vm.setEnv("ROYALTY_TEAM", vm.toString(address(0xFEE)));
        vm.setEnv("WETH_ADDRESS", "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
        vm.setEnv("EXTRA_STORAGE_WRITER", vm.toString(address(0)));
        // Foundry test simulation only; no transaction is sent to the RPC.
        vm.record();
        DeployPixelMarket.Deployed memory d = deployment.run();
        assertEq(address(d.canvasV2.zombieContract()), address(ZOMBIE));
        assertEq(address(d.rendererV6.zombieContract()), address(ZOMBIE));
        vm.prank(NFT.owner());
        NFT.setRendererContract(INormiesRenderer(address(d.rendererV6)));

        for (uint256 i; i < 21; i++) {
            assertTrue(ZOMBIE.isZombie(ids[i]));
            assertEq(_record(ids[i]), records[i], "assignment, base art and traits unchanged");
            string memory json = _decode(NFT.tokenURI(ids[i]));
            assertEq(vm.parseJsonString(json, ".attributes[0].value"), "Zombie");
        }
        (, bytes32[] memory converterWrites) = vm.accesses(address(ZOMBIE));
        (, bytes32[] memory storageWrites) = vm.accesses(address(ZOMBIE_STORAGE));
        assertEq(converterWrites.length, 0, "no conversion or campaign changes");
        assertEq(storageWrites.length, 0, "no new zombies or changes to existing assignments");
        assertEq(ZOMBIE.merkleRoot(), root);
        assertEq(ZOMBIE.seed(), seed);
        assertEq(ZOMBIE.nextCommitId(), nextCommit);
        assertEq(ZOMBIE.paused(), wasPaused);
        assertEq(ZOMBIE_STORAGE.authorizedWriters(address(ZOMBIE)), wasWriter);
        deployment.validateZombieCampaign(address(ZOMBIE), address(NFT));
    }

    function _record(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(ZOMBIE_STORAGE.poolIndexOf(id), ZOMBIE.getZombieBitmap(id), ZOMBIE.getZombieAttributes(id))
        );
    }

    function _decode(string memory uri) internal pure returns (string memory) {
        bytes memory value = bytes(uri);
        bytes memory encoded = new bytes(value.length - 29);
        for (uint256 i; i < encoded.length; i++) {
            encoded[i] = value[i + 29];
        }
        return string(Base64.decode(string(encoded)));
    }
}

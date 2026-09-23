// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "../PixelMarketBase.t.sol";
import { NormiesZombie } from "../../src/NormiesZombie.sol";
import { NormiesZombieStorage } from "../../src/NormiesZombieStorage.sol";
import { NormiesLegendaryCanvas } from "../../src/NormiesLegendaryCanvas.sol";
import { INormiesCanvas } from "../../src/interfaces/INormiesCanvas.sol";
import { INormiesStorage } from "../../src/interfaces/INormiesStorage.sol";
import { INormiesZombieStorage } from "../../src/interfaces/INormiesZombieStorage.sol";
import { INormiesLegendaryCanvas } from "../../src/interfaces/INormiesLegendaryCanvas.sol";

contract AdjacentReviewTest is PixelMarketBase {
    function _zombieStorage() internal returns (NormiesZombieStorage zs) {
        zs = new NormiesZombieStorage();
        for (uint256 i; i < 21; i++) {
            zs.addZombie(_createBitmapWithPixels(i + 1), bytes('{"trait_type":"Type","value":"Zombie"}'));
        }
        zs.sealPool();
    }

    function _zombie(NormiesZombieStorage zs, address eligibleCanvas) internal returns (NormiesZombie z) {
        z = new NormiesZombie(
            address(normies),
            INormiesStorage(address(normiesStorage)),
            INormiesCanvas(eligibleCanvas),
            INormiesZombieStorage(address(zs))
        );
        zs.setAuthorizedWriter(address(z), true);
        z.setMerkleRoot(z.leafHash(0, user));
        z.setSeedBlock(block.number + 1);
        vm.roll(block.number + 2);
        z.lockSeed();
        z.setPaused(false);
    }

    function testExistingZombieUsesFrozenV1LevelAfterV2Upgrade() public {
        _mintRealTo(user, 1);
        NormiesZombieStorage zs = _zombieStorage();
        NormiesZombie z = _zombie(zs, address(canvasV1));
        _giveTokenPixels(user, 1, 48);
        vm.prank(user);
        canvas.setTransformBitmap(1, _createBitmapWithPixels(20));
        assertGt(canvas.getLevel(1), 1);
        assertTrue(storageV2.isTransformed(1));
        assertEq(canvasV1.getLevel(1), 1);

        vm.prank(user);
        uint256 id = z.commitConvert(1, 0, user, new bytes32[](0), address(0));
        vm.roll(block.number + 6);
        z.revealConvert(id);
        assertTrue(zs.isZombie(1), "customized/high-level V2 token still passes the frozen V1 gate");
    }

    function testConversionEligibilityIsNotRecheckedOnReveal() public {
        _mintRealTo(user, 1);
        NormiesZombieStorage zs = _zombieStorage();
        NormiesZombie z = _zombie(zs, address(canvas));
        vm.prank(user);
        uint256 id = z.commitConvert(1, 0, user, new bytes32[](0), address(0));
        _giveTokenPixels(user, 1, 48);
        vm.prank(user);
        canvas.setTransformBitmap(1, _createBitmapWithPixels(20));
        assertGt(canvas.getLevel(1), 1);
        assertTrue(storageV2.isTransformed(1));
        assertTrue(z.tokenLocked(1));
        z.revealConvert(id);
        assertTrue(zs.isZombie(1), "the lock does not freeze level/art and reveal does not revalidate");
    }

    function testRedeployingZombieResetsConsumedClaimsAndReusesPool() public {
        _mintRealTo(user, 1);
        _mintRealTo(user, 2);
        NormiesZombieStorage zs = _zombieStorage();
        NormiesZombie oldZombie = _zombie(zs, address(canvasV1));
        vm.prank(user);
        uint256 id = oldZombie.commitConvert(1, 0, user, new bytes32[](0), address(0));
        vm.roll(block.number + 6);
        oldZombie.revealConvert(id);
        assertTrue(oldZombie.hasClaimed(user));
        oldZombie.setPaused(true);
        zs.setAuthorizedWriter(address(oldZombie), false);

        NormiesZombie newZombie = _zombie(zs, address(canvas));
        assertFalse(newZombie.hasClaimed(user));
        vm.prank(user);
        id = newZombie.commitConvert(2, 0, user, new bytes32[](0), address(0));
        vm.roll(block.number + 6);
        newZombie.revealConvert(id);
        assertTrue(zs.isZombie(1));
        assertTrue(zs.isZombie(2), "a consumed qualifying wallet claims twice after prescribed redeployment");
    }

    function parseJsonExternal(string calldata json) external pure returns (bytes memory) {
        return vm.parseJson(json);
    }

    function testQuotedArtistProducesInvalidRendererJSON() public {
        _mintRealTo(user, 1);
        NormiesLegendaryCanvas legendary = new NormiesLegendaryCanvas();
        renderer.setLegendaryCanvasContract(INormiesLegendaryCanvas(address(legendary)));
        legendary.setLegendaryCanvas(1, 'Quote " In Name');
        string memory json = _decodeTokenURI(renderer.tokenURI(1));
        assertTrue(_contains(json, '"value":"Quote " In Name"'));
        vm.expectRevert();
        this.parseJsonExternal(json);
    }
}


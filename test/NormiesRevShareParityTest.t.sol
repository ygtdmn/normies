// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";
import { MockWETH } from "./mocks/MockWETH.sol";

/**
 * @notice Claims an epoch built by the TypeScript scorer (api-server/src/revshare/merkle.ts) against the real pool.
 *         The fixture is written and checked by api-server/test/revshare-epoch.test.ts, so if the two sides ever
 *         disagree about leaves, hashing or proofs, one of the suites fails.
 */
contract NormiesRevShareParityTest is Test {
    function testScorerTreeClaimsAgainstThePool() public {
        string memory json = vm.readFile("./test/fixtures/revshare-epoch.json");
        bytes32 root = vm.parseJsonBytes32(json, ".root");
        uint256 total = vm.parseJsonUint(json, ".total");
        assertEq(vm.parseJsonUint(json, ".epochId"), 1);

        NormiesRevenuePool pool = new NormiesRevenuePool(IWETH(address(new MockWETH())));
        vm.deal(address(pool), total);
        vm.roll(1000);
        assertEq(pool.postEpoch(root, total, 1, 900, bytes32(0), ""), 1);
        vm.warp(block.timestamp + 48 hours);

        for (uint256 i; i < 5; i++) {
            string memory at = string.concat(".leaves[", vm.toString(i), "]");
            uint256 index = vm.parseJsonUint(json, string.concat(at, ".index"));
            address account = vm.parseJsonAddress(json, string.concat(at, ".account"));
            uint256 amount = vm.parseJsonUint(json, string.concat(at, ".amount"));
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, string.concat(at, ".proof"));
            pool.claim(1, index, account, amount, proof);
            assertEq(account.balance, amount);
        }
        // Every leaf claimed, to the wei: the scorer's total is exactly the sum of its leaves.
        assertEq(pool.outstanding(), 0);
        assertEq(address(pool).balance, 0);
    }
}

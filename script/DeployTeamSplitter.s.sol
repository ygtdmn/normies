// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Script } from "forge-std/src/Script.sol";
import { console } from "forge-std/src/console.sol";
import { NormiesTeamSplitter } from "../src/NormiesTeamSplitter.sol";

/**
 * @notice Deploys the team splitter: the team's half of royalties, split 90% / 10%. Nothing else is needed from the
 *         deployer: the contract has no owner.
 *
 *         forge script script/DeployTeamSplitter.s.sol --rpc-url mainnet --broadcast --verify --ledger
 *
 *         Then, from the Admin Safe: `release()` on the royalty splitter (so royalties already there go to the old
 *         team wallet), then `setTeam(<deployed address>)` on the royalty splitter
 *         (0xA68A225f62772E6158f2B5f8afC184AdB69c3282).
 */
contract DeployTeamSplitter is Script {
    address internal constant PRIMARY = 0x0391AbD7969D494a671F14ed01C85411A596BAEa;
    address internal constant SECONDARY = 0x20edb6cfA307495CFD2e10ca400346b0A15baA0A;
    uint256 internal constant PRIMARY_BPS = 9000;

    function run() public returns (NormiesTeamSplitter team) {
        vm.startBroadcast();
        team = new NormiesTeamSplitter(PRIMARY, SECONDARY, PRIMARY_BPS);
        vm.stopBroadcast();

        console.log("NormiesTeamSplitter", address(team));
        console.log("  primary   (90%)  ", team.primary());
        console.log("  secondary (10%)  ", team.secondary());
    }
}

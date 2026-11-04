// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { console } from "forge-std/src/console.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { NormiesTeamSplitter } from "../src/NormiesTeamSplitter.sol";
import { NormiesRoyaltySplitter } from "../src/NormiesRoyaltySplitter.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";

/// @notice Rehearses pointing the royalty splitter's `team` at the deployed team splitter, against live mainnet state:
///         the Admin Safe's `setTeam`, then `release()` on both splitters from an unrelated wallet. Skipped when
///         API_KEY_ALCHEMY is not configured. FORK_BLOCK pins a block; by default the latest one is used.
///
///         forge test --match-path test/NormiesTeamSplitterForkTest.t.sol -vv
contract NormiesTeamSplitterForkTest is Test {
    address constant NORMIES = 0x9Eb6E2025B64f340691e424b7fe7022fFDE12438;
    address constant ROYALTY_SPLITTER = 0xA68A225f62772E6158f2B5f8afC184AdB69c3282;
    address constant POOL = 0x481384812e79bf0d11FC0b1704af445D5F06813c;
    address constant ADMIN_SAFE = 0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant TEAM_SPLITTER = 0x5b4E255c7AA8d5a726D2D24CDc1CcF7213b1EC02;
    address constant PRIMARY = 0x0391AbD7969D494a671F14ed01C85411A596BAEa;
    address constant SECONDARY = 0x20edb6cfA307495CFD2e10ca400346b0A15baA0A;

    NormiesRoyaltySplitter royalties = NormiesRoyaltySplitter(payable(ROYALTY_SPLITTER));
    NormiesTeamSplitter team = NormiesTeamSplitter(payable(TEAM_SPLITTER));
    NormiesRevenuePool pool = NormiesRevenuePool(payable(POOL));
    address anyone = makeAddr("anyone");

    function setUp() public {
        if (bytes(vm.envOr("API_KEY_ALCHEMY", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork("mainnet");
        else vm.createSelectFork("mainnet", forkBlock);
        console.log("fork block", block.number);
    }

    /// The deployed contract is the code in this repo, with the agreed payees, and the live wiring is what we expect.
    function testDeployedTeamSplitterAndLiveWiring() public {
        assertGt(TEAM_SPLITTER.code.length, 0, "no code at the team splitter address");
        assertEq(keccak256(TEAM_SPLITTER.code), keccak256(_expectedRuntime()), "runtime differs from this repo");
        assertEq(team.primary(), PRIMARY);
        assertEq(team.secondary(), SECONDARY);
        assertEq(team.primaryBps(), 9000);

        assertEq(royalties.owner(), ADMIN_SAFE, "royalty splitter owner");
        assertEq(royalties.pool(), POOL, "royalty splitter pool");
        assertEq(royalties.poolBps(), 5000, "royalty splitter poolBps");
        (address receiver, uint256 amount) = IERC2981(NORMIES).royaltyInfo(1, 10_000);
        assertEq(receiver, ROYALTY_SPLITTER, "NFT royalty receiver");
        assertEq(amount, 500, "NFT royalty rate");
        console.log("current team          ", royalties.team());
    }

    /// The real sequence, with whatever the royalty splitter holds right now.
    function testSetTeamThenReleaseWithTodaysBalance() public {
        _run(0, 0);
    }

    /// The same, plus a sale (ETH, 2300 gas) and an accepted offer (WETH, no callback) landing after setTeam.
    function testSetTeamThenReleaseWithASaleAndAnOffer() public {
        _run(0.05 ether, 0.03 ether);
    }

    function _run(uint256 saleEth, uint256 offerWeth) internal {
        uint256 heldEth = ROYALTY_SPLITTER.balance;
        uint256 heldWeth = IWETH(WETH).balanceOf(ROYALTY_SPLITTER);
        console.log("royalty splitter ETH  ", heldEth);
        console.log("royalty splitter WETH ", heldWeth);
        console.log("team splitter ETH     ", TEAM_SPLITTER.balance);

        // 1. Admin Safe: setTeam.
        vm.expectEmit(true, false, false, false, ROYALTY_SPLITTER);
        emit NormiesRoyaltySplitter.TeamSet(TEAM_SPLITTER);
        vm.prank(ADMIN_SAFE);
        royalties.setTeam(TEAM_SPLITTER);
        assertEq(royalties.team(), TEAM_SPLITTER);

        // Optional: royalties arriving the way marketplaces pay them.
        if (saleEth > 0) {
            vm.deal(anyone, saleEth);
            vm.prank(anyone);
            payable(ROYALTY_SPLITTER).transfer(saleEth);
        }
        if (offerWeth > 0) {
            vm.deal(anyone, offerWeth);
            vm.startPrank(anyone);
            IWETH(WETH).deposit{ value: offerWeth }();
            IWETH(WETH).transfer(ROYALTY_SPLITTER, offerWeth);
            vm.stopPrank();
        }

        // 2. Anyone: release on the royalty splitter.
        uint256 total = heldEth + heldWeth + saleEth + offerWeth;
        uint256 toPool = (total * 5000) / 10_000;
        uint256 toTeam = total - toPool;
        uint256 poolBefore = POOL.balance;
        uint256 unallocatedBefore = pool.unallocated();
        uint256 teamBefore = TEAM_SPLITTER.balance;
        vm.prank(anyone);
        royalties.release();
        assertEq(ROYALTY_SPLITTER.balance, 0);
        assertEq(IWETH(WETH).balanceOf(ROYALTY_SPLITTER), 0);
        assertEq(POOL.balance - poolBefore, toPool, "pool share");
        assertEq(pool.unallocated() - unallocatedBefore, toPool, "pool unallocated");
        assertEq(TEAM_SPLITTER.balance - teamBefore, toTeam, "team splitter share");
        console.log("released total        ", total);
        console.log("  to pool             ", toPool);
        console.log("  to team splitter    ", toTeam);

        // 3. Anyone: release on the team splitter.
        uint256 teamTotal = TEAM_SPLITTER.balance;
        uint256 toPrimary = (teamTotal * 9000) / 10_000;
        uint256 toSecondary = teamTotal - toPrimary;
        uint256 primaryBefore = PRIMARY.balance;
        uint256 secondaryBefore = SECONDARY.balance;
        vm.prank(anyone);
        team.release();
        assertEq(TEAM_SPLITTER.balance, 0);
        assertEq(PRIMARY.balance - primaryBefore, toPrimary, "primary 90%");
        assertEq(SECONDARY.balance - secondaryBefore, toSecondary, "secondary 10%");
        console.log("team splitter paid    ", teamTotal);
        console.log("  to primary (90%)    ", toPrimary);
        console.log("  to secondary (10%)  ", toSecondary);
    }

    function _expectedRuntime() internal returns (bytes memory) {
        return address(new NormiesTeamSplitter(PRIMARY, SECONDARY, 9000)).code;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Ownable } from "solady/auth/Ownable.sol";
import { Test } from "forge-std/src/Test.sol";
import { NormiesRevenuePool } from "../src/NormiesRevenuePool.sol";
import { INormiesRevenuePool } from "../src/interfaces/INormiesRevenuePool.sol";
import { IWETH } from "../src/interfaces/IWETH.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

/// @notice Tries to claim a second time from inside its own payout.
contract ReentrantClaimer {
    NormiesRevenuePool pool;
    bytes32[] proof;
    uint256 epochId;
    uint256 index;
    uint256 amount;
    bool public attempted;

    constructor(NormiesRevenuePool _pool) {
        pool = _pool;
    }

    function arm(uint256 _epochId, uint256 _index, uint256 _amount, bytes32[] memory _proof) external {
        epochId = _epochId;
        index = _index;
        amount = _amount;
        proof = _proof;
    }

    receive() external payable {
        attempted = true;
        pool.claim(epochId, index, address(this), amount, proof);
    }
}

/// @notice Drives deposits, posts, claims, sweeps and owner withdrawals for the solvency invariant.
contract PoolHandler is Test {
    NormiesRevenuePool public pool;
    address[3] public accounts = [address(0xC1), address(0xC2), address(0xC3)];
    address public constant TREASURY = address(0xFEEE);
    uint256 public deposited;
    uint256 public paid;
    uint256 public withdrawn;
    uint256 public posts;
    uint256 public claims;
    uint256 public sweeps;
    uint256 public cancels;
    uint256 public withdrawals;

    struct Posted {
        uint256 id;
        uint256[3] amounts;
        bytes32[] tree;
    }

    Posted[] internal _posted;

    constructor(NormiesRevenuePool _pool) {
        pool = _pool;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 5 ether);
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(pool).call{ value: amount }("");
        require(ok);
        deposited += amount;
    }

    function post(uint256 a, uint256 b, uint256 c) external {
        uint256 free = pool.unallocated();
        if (free < 3) return;
        uint256[3] memory amounts = [bound(a, 1, free / 3), bound(b, 1, free / 3), bound(c, 1, free / 3)];
        uint256 id = pool.nextEpochId();
        bytes32[] memory leaves = new bytes32[](3);
        for (uint256 i; i < 3; i++) {
            leaves[i] = keccak256(bytes.concat(keccak256(abi.encode(id, i, accounts[i], amounts[i]))));
        }
        bytes32[] memory tree = MerkleTreeLib.build(leaves);
        uint64 from = pool.cursorToBlock() + 1;
        uint64 to = from + 10;
        if (block.number <= to) vm.roll(uint256(to) + 1);
        pool.postEpoch(MerkleTreeLib.root(tree), amounts[0] + amounts[1] + amounts[2], from, to, bytes32(0), "");
        _posted.push(Posted({ id: id, amounts: amounts, tree: tree }));
        posts++;
    }

    function setWindow(uint64 seconds_) external {
        pool.setClaimWindow(uint64(bound(seconds_, pool.MIN_CLAIM_WINDOW(), 730 days)));
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 400 days));
    }

    function claim(uint256 which, uint256 who) external {
        if (_posted.length == 0) return;
        Posted storage p = _posted[which % _posted.length];
        uint256 i = who % 3;
        INormiesRevenuePool.Epoch memory e = pool.getEpoch(p.id);
        if (e.status != INormiesRevenuePool.Status.Posted || pool.isClaimed(p.id, i)) return;
        if (block.timestamp < e.claimableAt) return;
        pool.claim(p.id, i, accounts[i], p.amounts[i], MerkleTreeLib.leafProof(p.tree, i));
        paid += p.amounts[i];
        claims++;
    }

    /// @dev The guardian path: withdraw an epoch before it opens; its reservation returns to the pool.
    function cancel(uint256 which) external {
        if (_posted.length == 0) return;
        uint256 id = _posted[which % _posted.length].id;
        INormiesRevenuePool.Epoch memory e = pool.getEpoch(id);
        if (e.status != INormiesRevenuePool.Status.Posted || block.timestamp >= e.claimableAt) return;
        pool.cancelEpoch(id);
        cancels++;
    }

    function sweep(uint256 which) external {
        if (_posted.length == 0) return;
        uint256 id = _posted[which % _posted.length].id;
        INormiesRevenuePool.Epoch memory e = pool.getEpoch(id);
        if (e.status != INormiesRevenuePool.Status.Posted) return;
        if (block.timestamp < e.sweepableAt) return;
        pool.sweep(id);
        sweeps++;
    }

    function withdraw(uint256 amount) external {
        uint256 free = pool.unallocated();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        pool.withdrawUnallocated(TREASURY, amount);
        withdrawn += amount;
        withdrawals++;
    }
}

contract NormiesRevenuePoolTest is Test {
    uint256 constant GUARDIAN = 1 << 0;
    uint256 constant POSTER = 1 << 2;

    NormiesRevenuePool pool;
    MockWETH weth;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    function setUp() public {
        weth = new MockWETH();
        pool = new NormiesRevenuePool(IWETH(address(weth)));
        vm.roll(1000);
        vm.warp(1_800_000_000);
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    function _leaf(uint256 epochId, uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, index, account, amount))));
    }

    function _tree(uint256 epochId, uint256[3] memory amounts) internal view returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = _leaf(epochId, 0, alice, amounts[0]);
        leaves[1] = _leaf(epochId, 1, bob, amounts[1]);
        leaves[2] = _leaf(epochId, 2, carol, amounts[2]);
        return MerkleTreeLib.build(leaves);
    }

    function _post(bytes32[] memory tree, uint256 amount, uint64 fromBlock, uint64 toBlock) internal returns (uint256) {
        return pool.postEpoch(MerkleTreeLib.root(tree), amount, fromBlock, toBlock, keccak256("config"), "ipfs://epoch");
    }

    function _fundAndPost() internal returns (uint256 id, bytes32[] memory tree, uint256[3] memory amounts) {
        vm.deal(address(pool), 10 ether);
        amounts = [uint256(1 ether), 2 ether, 3 ether];
        tree = _tree(1, amounts);
        id = _post(tree, 6 ether, 100, 900);
    }

    // ──────────────────────────────────────────────
    //  Posting
    // ──────────────────────────────────────────────

    function testPostReservesImmediately() public {
        (uint256 id,,) = _fundAndPost();
        assertEq(id, 1);
        assertEq(pool.outstanding(), 6 ether);
        assertEq(pool.unallocated(), 4 ether);
        INormiesRevenuePool.Epoch memory e = pool.getEpoch(1);
        assertEq(e.amount, 6 ether);
        assertEq(e.claimableAt, block.timestamp + pool.POST_DELAY());
        assertEq(e.sweepableAt, block.timestamp + pool.POST_DELAY() + 365 days);
        assertEq(uint8(e.status), uint8(INormiesRevenuePool.Status.Posted));
    }

    function testPostGuards() public {
        vm.deal(address(pool), 1 ether);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.postEpoch(bytes32(uint256(1)), 1, 1, 2, bytes32(0), "");
        vm.expectRevert(NormiesRevenuePool.InvalidEpoch.selector);
        pool.postEpoch(bytes32(0), 1, 1, 2, bytes32(0), "");
        vm.expectRevert(NormiesRevenuePool.InvalidEpoch.selector);
        pool.postEpoch(bytes32(uint256(1)), 0, 1, 2, bytes32(0), "");
        vm.expectRevert(NormiesRevenuePool.InvalidEpoch.selector);
        pool.postEpoch(bytes32(uint256(1)), 1, 1, uint64(block.number), bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.InsufficientUnallocated.selector, 1 ether, 2 ether));
        pool.postEpoch(bytes32(uint256(1)), 2 ether, 1, 2, bytes32(0), "");
    }

    function testContiguousRanges() public {
        _fundAndPost();
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.BlockRangeNotContiguous.selector, 901, 905));
        pool.postEpoch(bytes32(uint256(1)), 1 ether, 905, 950, bytes32(0), "");
        assertEq(pool.postEpoch(bytes32(uint256(1)), 1 ether, 901, 950, bytes32(0), ""), 2);
    }

    function testPauseBlocksPostingNotClaims() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        pool.setPaused(true);
        vm.warp(block.timestamp + 48 hours);
        pool.claim(id, 0, alice, 1 ether, MerkleTreeLib.leafProof(tree, 0));
        assertEq(alice.balance, 1 ether);
        vm.expectRevert(NormiesRevenuePool.Paused.selector);
        pool.postEpoch(bytes32(uint256(1)), 1 ether, 901, 950, bytes32(0), "");
    }

    // ──────────────────────────────────────────────
    //  Claims
    // ──────────────────────────────────────────────

    function testClaimPaysTheAccountWhoeverSubmits() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(carol);
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
        assertEq(bob.balance, 2 ether);
        assertEq(carol.balance, 0);
        assertTrue(pool.isClaimed(id, 1));
        assertEq(pool.outstanding(), 4 ether);
        assertEq(pool.getEpoch(id).claimed, 2 ether);

        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.AlreadyClaimed.selector, id, 1));
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
    }

    function testBadProofsRevert() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        vm.warp(block.timestamp + 48 hours);
        bytes32[] memory proof = MerkleTreeLib.leafProof(tree, 0);
        vm.expectRevert(NormiesRevenuePool.InvalidProof.selector);
        pool.claim(id, 0, alice, 2 ether, proof); // wrong amount
        vm.expectRevert(NormiesRevenuePool.InvalidProof.selector);
        pool.claim(id, 0, bob, 1 ether, proof); // wrong account
        vm.expectRevert(NormiesRevenuePool.InvalidProof.selector);
        pool.claim(id, 1, alice, 1 ether, proof); // wrong index
    }

    function testClaimMany() public {
        (uint256 id, bytes32[] memory tree, uint256[3] memory amounts) = _fundAndPost();
        vm.warp(block.timestamp + 48 hours);
        INormiesRevenuePool.Claim[] memory claims = new INormiesRevenuePool.Claim[](2);
        claims[0] = INormiesRevenuePool.Claim(id, 0, alice, amounts[0], MerkleTreeLib.leafProof(tree, 0));
        claims[1] = INormiesRevenuePool.Claim(id, 2, carol, amounts[2], MerkleTreeLib.leafProof(tree, 2));
        pool.claimMany(claims);
        assertEq(alice.balance, 1 ether);
        assertEq(carol.balance, 3 ether);
        assertEq(pool.outstanding(), 2 ether);
    }

    function testRootCanNeverPayMoreThanItsEpochReserved() public {
        // A root whose leaves add up to 6 ETH, posted as a 4 ETH epoch, next to another epoch's 5 ETH.
        vm.deal(address(pool), 9 ether);
        uint256[3] memory amounts = [uint256(1 ether), 2 ether, 3 ether];
        bytes32[] memory tree = _tree(1, amounts);
        uint256 id = _post(tree, 4 ether, 100, 900);
        vm.warp(block.timestamp + 48 hours);
        pool.claim(id, 2, carol, 3 ether, MerkleTreeLib.leafProof(tree, 2));
        pool.claim(id, 0, alice, 1 ether, MerkleTreeLib.leafProof(tree, 0));
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.EpochCapExceeded.selector, id));
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
        assertEq(pool.unallocated(), 5 ether);
    }

    function testSingleLeafTreeClaimsWithAnEmptyProof() public {
        vm.deal(address(pool), 1 ether);
        bytes32 leaf = _leaf(1, 0, alice, 1 ether);
        uint256 id = pool.postEpoch(leaf, 1 ether, 100, 900, bytes32(0), "");
        vm.warp(block.timestamp + 48 hours);
        pool.claim(id, 0, alice, 1 ether, new bytes32[](0));
        assertEq(alice.balance, 1 ether);
    }

    function testReentrantClaimerIsPaidOnce() public {
        ReentrantClaimer hostile = new ReentrantClaimer(pool);
        vm.deal(address(pool), 4 ether);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(1, 0, address(hostile), 1 ether);
        leaves[1] = _leaf(1, 1, bob, 1 ether);
        bytes32[] memory tree = MerkleTreeLib.build(leaves);
        uint256 id = _post(tree, 2 ether, 100, 900);
        vm.warp(block.timestamp + 48 hours);
        hostile.arm(id, 0, 1 ether, MerkleTreeLib.leafProof(tree, 0));
        pool.claim(id, 0, address(hostile), 1 ether, MerkleTreeLib.leafProof(tree, 0));
        // The nested claim reverts inside receive(); the forced transfer still delivers the single payout.
        assertEq(address(hostile).balance, 1 ether);
        assertEq(pool.outstanding(), 1 ether);
    }

    // ──────────────────────────────────────────────
    //  Sweep
    // ──────────────────────────────────────────────

    function testSweepReturnsLeftoversToThePoolOnly() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        vm.warp(block.timestamp + 48 hours);
        pool.claim(id, 0, alice, 1 ether, MerkleTreeLib.leafProof(tree, 0));

        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, id));
        pool.sweep(id);

        vm.warp(block.timestamp + 365 days);
        uint256 balanceBefore = address(pool).balance;
        vm.prank(carol); // anyone
        pool.sweep(id);
        assertEq(address(pool).balance, balanceBefore);
        assertEq(pool.outstanding(), 0);
        assertEq(pool.unallocated(), 9 ether);

        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.NotClaimable.selector, id));
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.NotClaimable.selector, id));
        pool.sweep(id);
    }

    // ──────────────────────────────────────────────
    //  WETH and admin
    // ──────────────────────────────────────────────

    function testUnwrapWorksOnA2300GasStipend() public {
        vm.deal(address(this), 2 ether);
        weth.deposit{ value: 2 ether }();
        weth.transfer(address(pool), 2 ether);
        assertEq(pool.unallocated(), 0);
        pool.unwrap();
        assertEq(pool.unallocated(), 2 ether);
        assertEq(weth.balanceOf(address(pool)), 0);
    }

    function testOwnerTakesOnlyWhatNoEpochReserved() public {
        vm.expectRevert(NormiesRevenuePool.CannotRescueWeth.selector);
        pool.rescueToken(address(weth), address(this));
        _fundAndPost(); // 10 ether in, 6 reserved
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.withdrawUnallocated(alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.InsufficientUnallocated.selector, 4 ether, 5 ether));
        pool.withdrawUnallocated(alice, 5 ether);
        pool.withdrawUnallocated(alice, 4 ether);
        assertEq(alice.balance, 4 ether);
        assertEq(pool.unallocated(), 0);
        assertEq(address(pool).balance, pool.outstanding());
    }

    function testClaimsOpenAfterThePostDelayAndWindowChangesAffectOnlyFutureEpochs() public {
        (uint256 id, bytes32[] memory tree,) = _fundAndPost();
        uint64 opensAt = uint64(block.timestamp + pool.POST_DELAY());
        bytes32[] memory proof = MerkleTreeLib.leafProof(tree, 0);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimsNotOpen.selector, id, opensAt));
        pool.claim(id, 0, alice, 1 ether, proof);
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimsNotOpen.selector, id, opensAt));
        pool.claim(id, 0, alice, 1 ether, proof);
        vm.warp(opensAt);
        pool.claim(id, 0, alice, 1 ether, proof);
        assertEq(alice.balance, 1 ether);

        pool.setClaimWindow(30 days);
        bytes32[] memory laterTree = _tree(2, [uint256(1 ether), 1 ether, 1 ether]);
        uint256 later = _post(laterTree, 3 ether, 901, 950);
        uint256 laterOpens = block.timestamp + pool.POST_DELAY();
        assertEq(pool.getEpoch(id).sweepableAt, opensAt + 365 days);
        assertEq(pool.getEpoch(later).sweepableAt, laterOpens + 30 days);

        vm.warp(laterOpens + 30 days - 1);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, later));
        pool.sweep(later);
        vm.warp(laterOpens + 30 days);
        pool.sweep(later);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, id));
        pool.sweep(id);
        pool.claim(id, 1, bob, 2 ether, MerkleTreeLib.leafProof(tree, 1));
        assertEq(bob.balance, 2 ether);
        assertEq(pool.outstanding(), 3 ether);

        vm.warp(uint256(opensAt) + 365 days);
        pool.sweep(id);
        assertEq(pool.outstanding(), 0);
    }

    function testIncreasingWindowDoesNotExtendExistingEpoch() public {
        uint64 minimum = pool.MIN_CLAIM_WINDOW();
        pool.setClaimWindow(minimum);
        (uint256 id,,) = _fundAndPost();
        uint256 opensAt = block.timestamp + pool.POST_DELAY();
        pool.setClaimWindow(730 days);
        uint256 later = pool.postEpoch(bytes32(uint256(1)), 1 ether, 901, 950, bytes32(0), "");
        assertEq(pool.getEpoch(id).sweepableAt, opensAt + minimum);
        assertEq(pool.getEpoch(later).sweepableAt, opensAt + 730 days);

        vm.warp(opensAt + minimum);
        pool.sweep(id);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, later));
        pool.sweep(later);
        assertEq(pool.outstanding(), 1 ether);
    }

    function testClaimWindowMinimumAndOwnership() public {
        uint64 minimum = pool.MIN_CLAIM_WINDOW();
        assertEq(minimum, 1 days);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowTooShort.selector, 0, minimum));
        pool.setClaimWindow(0);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowTooShort.selector, minimum - 1, minimum));
        pool.setClaimWindow(minimum - 1);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.setClaimWindow(minimum);
        pool.setClaimWindow(minimum);
        assertEq(pool.claimWindow(), minimum);
    }

    function testPostEmitsFixedDeadline() public {
        vm.deal(address(pool), 1 ether);
        uint64 opensAt = uint64(block.timestamp) + pool.POST_DELAY();
        uint64 deadline = opensAt + pool.claimWindow();
        bytes32 root = _leaf(1, 0, alice, 1 ether);
        vm.expectEmit(true, false, false, true, address(pool));
        emit NormiesRevenuePool.EpochPosted(1, root, 1 ether, 100, 900, opensAt, deadline, bytes32(0), "");
        pool.postEpoch(root, 1 ether, 100, 900, bytes32(0), "");
        assertEq(pool.getEpoch(1).sweepableAt, deadline);
    }

    // ──────────────────────────────────────────────
    //  Cancelling before claims open, and who may do what
    // ──────────────────────────────────────────────

    function testGuardianCancelsAnUnopenedEpochAndItsRangeCanBePostedAgain() public {
        address guardian = address(0x6A4D);
        pool.grantRoles(guardian, GUARDIAN);
        (uint256 id, bytes32[] memory tree,) = _fundAndPost(); // blocks 100..900, 6 of 10 ether
        assertEq(pool.cursorToBlock(), 900);

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.cancelEpoch(id);

        vm.expectEmit(true, false, false, true, address(pool));
        emit NormiesRevenuePool.EpochCancelled(id, 6 ether, 99);
        vm.prank(guardian);
        pool.cancelEpoch(id);
        assertEq(uint8(pool.getEpoch(id).status), uint8(INormiesRevenuePool.Status.Cancelled));
        assertEq(pool.outstanding(), 0);
        assertEq(pool.unallocated(), 10 ether);

        // Nothing can be claimed or swept from it, ever.
        vm.warp(block.timestamp + 400 days);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.NotClaimable.selector, id));
        pool.claim(id, 0, alice, 1 ether, MerkleTreeLib.leafProof(tree, 0));
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.NotClaimable.selector, id));
        pool.sweep(id);

        // The same range goes out again under a new id.
        uint256 again = _post(_tree(2, [uint256(1 ether), 2 ether, 3 ether]), 6 ether, 100, 900);
        assertEq(again, 2);
        assertEq(pool.cursorToBlock(), 900);
    }

    function testNothingIsCancelledOnceClaimsOpen() public {
        (uint256 id,,) = _fundAndPost();
        vm.warp(block.timestamp + pool.POST_DELAY());
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.EpochAlreadyOpen.selector, id));
        pool.cancelEpoch(id);
    }

    function testCancellingAnOlderEpochKeepsTheLatestRange() public {
        (uint256 first,,) = _fundAndPost(); // 100..900
        uint256 second = _post(_tree(2, [uint256(1 ether), 1 ether, 1 ether]), 3 ether, 901, 950);
        pool.cancelEpoch(first);
        assertEq(pool.cursorToBlock(), 950);
        assertEq(pool.outstanding(), 3 ether);
        assertEq(uint8(pool.getEpoch(second).status), uint8(INormiesRevenuePool.Status.Posted));
    }

    function testPosterOnlyPostsAndTheGuardianPausesBothWays() public {
        address poster = address(0x9057);
        address guardian = address(0x6A4D);
        pool.grantRoles(poster, POSTER);
        pool.grantRoles(guardian, GUARDIAN);
        vm.deal(address(pool), 1 ether);

        vm.prank(poster);
        uint256 id = pool.postEpoch(_leaf(1, 0, alice, 1 ether), 1 ether, 100, 900, bytes32(0), "");
        vm.startPrank(poster);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.withdrawUnallocated(poster, 0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.cancelEpoch(id);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.setPaused(true);
        vm.stopPrank();

        vm.prank(guardian);
        pool.setPaused(true);
        vm.prank(guardian);
        pool.setPaused(false); // at once
        assertFalse(pool.paused());
        pool.setPaused(true); // the owner can too
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        pool.setPaused(false);
    }

    function testFuzzWindowChangesCannotAlterPostedDeadline(uint64 initial, uint64 updated) public {
        uint64 minimum = pool.MIN_CLAIM_WINDOW();
        initial = uint64(bound(initial, minimum, 3650 days));
        updated = uint64(bound(updated, minimum, 3650 days));
        pool.setClaimWindow(initial);
        (uint256 id,,) = _fundAndPost();
        uint256 deadline = block.timestamp + pool.POST_DELAY() + initial;
        pool.setClaimWindow(updated);
        assertEq(pool.getEpoch(id).sweepableAt, deadline);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(NormiesRevenuePool.ClaimWindowOpen.selector, id));
        pool.sweep(id);
        vm.warp(deadline);
        pool.sweep(id);
        assertEq(pool.outstanding(), 0);
    }
}

contract NormiesRevenuePoolInvariantTest is Test {
    NormiesRevenuePool pool;
    PoolHandler handler;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_800_000_000);
        pool = new NormiesRevenuePool(IWETH(address(new MockWETH())));
        handler = new PoolHandler(pool);
        pool.transferOwnership(address(handler));

        // Exercise every operation before fuzzing, leaving both live and swept epochs.
        handler.deposit(5 ether);
        handler.post(1 ether, 1 ether, 1 ether);
        vm.warp(block.timestamp + pool.POST_DELAY()); // claims open after the post delay
        handler.claim(0, 1);
        handler.warp(366 days);
        handler.sweep(0);
        handler.withdraw(1 ether);
        handler.post(1 ether, 1 ether, 1 ether);
        handler.cancel(1); // cancelled before it opened: its range is posted again below
        handler.post(1 ether, 1 ether, 1 ether);
        vm.warp(block.timestamp + pool.POST_DELAY());
        handler.claim(2, 0);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.fail-on-revert = true
    function invariant_poolReservationsAndCashAreConserved() public view {
        uint256 reserved;
        for (uint256 id = 1; id < pool.nextEpochId(); id++) {
            INormiesRevenuePool.Epoch memory e = pool.getEpoch(id);
            assertLe(e.claimed, e.amount);
            if (e.status == INormiesRevenuePool.Status.Posted) reserved += uint256(e.amount) - e.claimed;
        }
        assertEq(pool.owner(), address(handler));
        assertEq(pool.outstanding(), reserved);
        assertGe(address(pool).balance, reserved);
        assertEq(address(pool).balance + handler.paid() + handler.withdrawn(), handler.deposited());
        assertEq(handler.TREASURY().balance, handler.withdrawn());
        uint256 received;
        for (uint256 i; i < 3; i++) {
            received += handler.accounts(i).balance;
        }
        assertEq(received, handler.paid());
        assertEq(pool.nextEpochId(), handler.posts() + 1);
        assertGe(handler.posts(), 3);
        assertGe(handler.cancels(), 1);
        assertGe(handler.claims(), 2);
        assertGe(handler.sweeps(), 1);
        assertGe(handler.withdrawals(), 1);
    }
}

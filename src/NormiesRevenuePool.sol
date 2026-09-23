// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesRevenuePool } from "./interfaces/INormiesRevenuePool.sol";
import { IWETH } from "./interfaces/IWETH.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MerkleProofLib } from "solady/utils/MerkleProofLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { ReentrancyGuardTransient } from "solady/utils/ReentrancyGuardTransient.sol";

/**
 * @title NormiesRevenuePool
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Holds the holders' share of Pixel Market fees and collection royalties and pays it out in epochs.
 *         Scores depend on what every wallet holds over time, which no contract can see, so an open-source scorer
 *         computes each epoch's payouts from chain data and the owner publishes their Merkle root here; claims open
 *         at once. The revenue share is run on the owner's word: the owner posts the roots, can pause posting and
 *         can withdraw ETH no epoch has reserved. What holders are owed is reserved the moment a root is posted and
 *         can only leave through claims; a root can never pay out more than its epoch holds; what goes unclaimed
 *         after its fixed claim window rolls back into the pool. Later default-window changes cannot alter
 *         the deadline promised to an already-posted epoch.
 */
contract NormiesRevenuePool is INormiesRevenuePool, Ownable, ReentrancyGuardTransient {
    using SafeCastLib for uint256;

    error Paused();
    error InvalidEpoch();
    error BlockRangeNotContiguous(uint64 expectedFromBlock, uint64 fromBlock);
    error InsufficientUnallocated(uint256 unallocated, uint256 amount);
    error NotClaimable(uint256 epochId);
    error AlreadyClaimed(uint256 epochId, uint256 index);
    error InvalidProof();
    error EpochCapExceeded(uint256 epochId);
    error ClaimWindowOpen(uint256 epochId);
    error ClaimWindowTooShort(uint64 requested, uint64 minimum);
    error ZeroAddress();
    error CannotRescueWeth();

    event EpochPosted(
        uint256 indexed epochId,
        bytes32 root,
        uint256 amount,
        uint64 fromBlock,
        uint64 toBlock,
        uint64 claimableAt,
        uint64 sweepableAt,
        bytes32 configHash,
        string dataURI
    );
    event Claimed(uint256 indexed epochId, uint256 indexed index, address indexed account, uint256 amount);
    event Swept(uint256 indexed epochId, uint256 returnedToPool);
    event Unwrapped(uint256 amount);
    event ClaimWindowSet(uint64 claimWindow);
    event Withdrawn(address indexed to, uint256 amount);
    event PausedSet(bool paused);

    IWETH public immutable weth;

    mapping(uint256 => Epoch) internal _epochs;
    mapping(uint256 => mapping(uint256 => uint256)) internal _claimedBitmap;

    uint256 public nextEpochId = 1;
    /// @notice ETH reserved for holders: every posted epoch's amount, minus what was claimed or swept.
    uint256 public outstanding;
    /// @notice Last block covered by a posted epoch. The next epoch has to start right after it.
    uint64 public cursorToBlock;

    /// @notice Minimum guaranteed claim window for newly posted epochs.
    uint64 public constant MIN_CLAIM_WINDOW = 1 days;
    /// @notice Default window for future epochs only; each posted epoch retains its own sweepableAt.
    uint64 public claimWindow = 365 days;
    /// @notice Blocks posting only. Claims on a posted epoch can never be paused.
    bool public paused;

    constructor(IWETH _weth) Ownable() {
        weth = _weth;
    }

    /// @dev Kept empty on purpose: marketplaces pay in the middle of a sale and WETH unwraps forward 2300 gas, so
    ///      this must never revert or cost more than a bare transfer.
    receive() external payable { }

    // ──────────────────────────────────────────────
    //  Views
    // ──────────────────────────────────────────────

    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    function isClaimed(uint256 epochId, uint256 index) public view returns (bool) {
        return (_claimedBitmap[epochId][index >> 8] >> (index & 0xff)) & 1 == 1;
    }

    /// @notice ETH in the pool that no epoch has reserved yet.
    function unallocated() public view returns (uint256) {
        return address(this).balance - outstanding;
    }

    // ──────────────────────────────────────────────
    //  Epochs
    // ──────────────────────────────────────────────

    /**
     * @notice Publish an epoch's Merkle root. `amount` is the sum of its leaves and is reserved immediately, so a
     *         later epoch can never be promised the same ETH. Claims open in the same block. Block ranges have to
     *         follow each other without gaps. The current claimWindow fixes sweepableAt for this epoch.
     * @param configHash Hash of the scoring config the root was computed with.
     * @param dataURI    Where the full payout table and proofs are published.
     */
    function postEpoch(
        bytes32 root,
        uint256 amount,
        uint64 fromBlock,
        uint64 toBlock,
        bytes32 configHash,
        string calldata dataURI
    ) external onlyOwner returns (uint256 epochId) {
        require(!paused, Paused());
        require(root != bytes32(0) && amount > 0 && toBlock >= fromBlock && toBlock < block.number, InvalidEpoch());

        uint64 cursor = cursorToBlock;
        require(cursor == 0 || fromBlock == cursor + 1, BlockRangeNotContiguous(cursor + 1, fromBlock));

        uint256 free = unallocated();
        require(amount <= free, InsufficientUnallocated(free, amount));

        epochId = nextEpochId++;
        uint64 claimableAt = block.timestamp.toUint64();
        uint64 sweepableAt = (block.timestamp + claimWindow).toUint64();
        _epochs[epochId] = Epoch({
            root: root,
            amount: amount.toUint128(),
            claimed: 0,
            claimableAt: claimableAt,
            sweepableAt: sweepableAt,
            fromBlock: fromBlock,
            toBlock: toBlock,
            status: Status.Posted
        });
        outstanding += amount;
        cursorToBlock = toBlock;

        emit EpochPosted(epochId, root, amount, fromBlock, toBlock, claimableAt, sweepableAt, configHash, dataURI);
    }

    // ──────────────────────────────────────────────
    //  Claims
    // ──────────────────────────────────────────────

    /// @notice Pay `account` its share of an epoch. Anyone can submit the proof; the ETH only ever goes to `account`.
    function claim(
        uint256 epochId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant {
        _claim(epochId, index, account, amount, proof);
    }

    function claimMany(Claim[] calldata claims) external nonReentrant {
        for (uint256 i; i < claims.length; i++) {
            Claim calldata c = claims[i];
            _claim(c.epochId, c.index, c.account, c.amount, c.proof);
        }
    }

    function _claim(
        uint256 epochId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata proof
    ) internal {
        Epoch storage epoch = _epochs[epochId];
        require(epoch.status == Status.Posted, NotClaimable(epochId));
        require(!isClaimed(epochId, index), AlreadyClaimed(epochId, index));

        // Same leaf shape as OpenZeppelin's StandardMerkleTree: double hashed, abi.encode of the values.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(epochId, index, account, amount))));
        require(MerkleProofLib.verifyCalldata(proof, epoch.root, leaf), InvalidProof());

        // A root is not trusted to add up: it can never pay out more than the epoch reserved.
        uint256 claimed = uint256(epoch.claimed) + amount;
        require(claimed <= epoch.amount, EpochCapExceeded(epochId));

        _claimedBitmap[epochId][index >> 8] |= 1 << (index & 0xff);
        epoch.claimed = uint128(claimed);
        outstanding -= amount;

        SafeTransferLib.forceSafeTransferETH(account, amount);
        emit Claimed(epochId, index, account, amount);
    }

    /// @notice Once an epoch's fixed sweepableAt is reached, anyone can return its unclaimed funds to the pool.
    ///         Claims remain available until the epoch is actually swept.
    function sweep(uint256 epochId) external {
        Epoch storage epoch = _epochs[epochId];
        require(epoch.status == Status.Posted, NotClaimable(epochId));
        require(block.timestamp >= epoch.sweepableAt, ClaimWindowOpen(epochId));
        uint256 leftover = uint256(epoch.amount) - epoch.claimed;
        epoch.status = Status.Swept;
        outstanding -= leftover;
        emit Swept(epochId, leftover);
    }

    /// @notice Turns any WETH the pool holds (royalties from accepted offers arrive as WETH) into ETH.
    function unwrap() external {
        uint256 balance = weth.balanceOf(address(this));
        if (balance == 0) return;
        weth.withdraw(balance);
        emit Unwrapped(balance);
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    /// @notice Sets the window for future epochs only. Posted deadlines cannot be shortened or extended.
    function setClaimWindow(uint64 _claimWindow) external onlyOwner {
        require(_claimWindow >= MIN_CLAIM_WINDOW, ClaimWindowTooShort(_claimWindow, MIN_CLAIM_WINDOW));
        claimWindow = _claimWindow;
        emit ClaimWindowSet(_claimWindow);
    }

    /// @notice Takes ETH no epoch has reserved. What a posted root owes its holders cannot be touched.
    function withdrawUnallocated(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), ZeroAddress());
        uint256 free = unallocated();
        require(amount <= free, InsufficientUnallocated(free, amount));
        SafeTransferLib.forceSafeTransferETH(to, amount);
        emit Withdrawn(to, amount);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Recovers a token sent here by mistake. WETH is pool revenue and can only be unwrapped.
    function rescueToken(address token, address to) external onlyOwner {
        require(token != address(weth), CannotRescueWeth());
        require(to != address(0), ZeroAddress());
        SafeTransferLib.safeTransferAll(token, to);
    }
}

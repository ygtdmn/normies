// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesStorage } from "./interfaces/INormiesStorage.sol";
import { INormies } from "./interfaces/INormies.sol";
import { INormiesCanvasStorage } from "./interfaces/INormiesCanvasStorage.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";
import { ReentrancyGuardTransient } from "solady/utils/ReentrancyGuardTransient.sol";

/**
 * @title NormiesCanvas
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 */
contract NormiesCanvas is Ownable, Lifebuoy, ReentrancyGuardTransient {
    struct BurnCommitment {
        address owner;
        uint256 receiverTokenId;
        uint64 commitBlock;
        uint16 tokenCount;
        bool revealed;
        uint256 transferredActionPoints;
        uint256[] pixelCounts;
    }

    error NotTokenOwner();
    error NotTokenOwnerOrDelegate();
    error NotTokenOwnerForDelegation();
    error InvalidDelegate();
    error InsufficientTransformActions();
    error InvalidBitmapLength();
    error Paused();
    error NoTokensProvided();
    error CannotBurnReceiver();
    error TooEarlyToReveal();
    error AlreadyRevealed();
    error CommitmentNotFound();

    event BurnCommitted(
        uint256 indexed commitId,
        address indexed owner,
        uint256 indexed receiverTokenId,
        uint256 tokenCount,
        uint256 transferredActionPoints
    );
    event BurnRevealed(
        uint256 indexed commitId,
        address indexed owner,
        uint256 indexed receiverTokenId,
        uint256 totalActions,
        bool expired
    );
    event PixelsTransformed(
        address indexed transformer, uint256 indexed tokenId, uint256 changeCount, uint256 newPixelCount
    );
    event DelegateSet(uint256 indexed tokenId, address indexed delegate);
    event DelegateRevoked(uint256 indexed tokenId, address indexed previousDelegate);

    IERC721 public immutable normies;
    INormiesStorage public immutable normiesStorage;
    INormiesCanvasStorage public canvasStorage;

    /// @notice Non-transferable pixel transform budget per token (max changed pixels allowed)
    mapping(uint256 => uint256) public actionPoints;

    /// @notice Returns the display level for a token (base 1 + 1 per 10 action points)
    function getLevel(uint256 tokenId) external view returns (uint256) {
        return actionPoints[tokenId] / 10 + 1;
    }

    /// @notice Per-token transform delegate (one delegate per token, set by owner)
    mapping(uint256 => address) public delegates;

    /// @notice Tracks which owner set the delegate (used to auto-invalidate on transfer)
    mapping(uint256 => address) public delegateSetBy;

    /// @notice Commit-reveal state for burns
    mapping(uint256 => BurnCommitment) public burnCommitments;
    mapping(address => uint256[]) private _userPendingCommitIds;
    uint256 public nextCommitId;

    /// @notice Number of blocks to wait before reveal is allowed
    uint256 public constant REVEAL_DELAY = 5;

    /// @notice Burn scaling config (adjustable by owner)
    uint256 public maxBurnPercent = 4;
    uint256[2] public tierThresholds = [uint256(490), 890];
    uint256[3] public tierMinPercents = [uint256(1), 2, 3];

    bool public paused;

    constructor(
        address _normies,
        INormiesStorage _originalStorage,
        INormiesCanvasStorage _transformStorage
    ) Ownable() Lifebuoy() {
        normies = IERC721(_normies);
        normiesStorage = _originalStorage;
        canvasStorage = _transformStorage;
    }

    modifier whenNotPaused() {
        require(!paused, Paused());
        _;
    }

    // ──────────────────────────────────────────────
    //  Burn: Commit-Reveal
    // ──────────────────────────────────────────────

    /**
     * @notice Phase 1: Burn Normies and commit pixel counts. Tokens are burned immediately.
     *         Actions are credited later on reveal (after REVEAL_DELAY blocks) to prevent gaming.
     * @param tokenIds Array of token IDs to burn
     * @param receiverTokenId Token that receives the earned transform actions (must be owned by caller)
     */
    function commitBurn(uint256[] calldata tokenIds, uint256 receiverTokenId) external whenNotPaused nonReentrant {
        require(tokenIds.length > 0, NoTokensProvided());
        require(normies.ownerOf(receiverTokenId) == msg.sender, NotTokenOwner());

        uint256 commitId = nextCommitId++;
        BurnCommitment storage commitment = burnCommitments[commitId];
        commitment.owner = msg.sender;
        commitment.receiverTokenId = receiverTokenId;
        commitment.commitBlock = uint64(block.number);
        commitment.tokenCount = uint16(tokenIds.length);

        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            require(normies.ownerOf(tokenId) == msg.sender, NotTokenOwner());
            require(tokenId != receiverTokenId, CannotBurnReceiver());

            bytes memory bitmap = normiesStorage.getTokenRawImageData(tokenId);
            commitment.pixelCounts.push(_countPixels(bitmap));

            uint256 ap = actionPoints[tokenId];
            if (ap > 0) {
                commitment.transferredActionPoints += ap;
                delete actionPoints[tokenId];
            }

            INormies(address(normies)).burn(tokenId);
        }
        _userPendingCommitIds[msg.sender].push(commitId);

        emit BurnCommitted(commitId, msg.sender, receiverTokenId, tokenIds.length, commitment.transferredActionPoints);
    }

    /**
     * @notice Phase 2: Reveal a burn commitment after REVEAL_DELAY blocks to credit transform actions.
     *         Uses blockhash of (commitBlock + REVEAL_DELAY) as entropy for percentage roll.
     *         If the reveal window has expired (>256 blocks), falls back to minimum tier percentages.
     * @param commitId The commitment ID returned from commitBurn
     */
    function revealBurn(uint256 commitId) external whenNotPaused nonReentrant {
        BurnCommitment storage commitment = burnCommitments[commitId];
        require(commitment.tokenCount > 0, CommitmentNotFound());
        require(!commitment.revealed, AlreadyRevealed());
        require(block.number > commitment.commitBlock + REVEAL_DELAY, TooEarlyToReveal());

        bytes32 entropy = blockhash(commitment.commitBlock + REVEAL_DELAY);
        bool expired = entropy == bytes32(0);

        uint256 totalActions;
        uint256[] storage pixelCounts = commitment.pixelCounts;
        for (uint256 i; i < pixelCounts.length; i++) {
            uint256 pixelCount = pixelCounts[i];
            uint256 percentage;
            if (expired) {
                percentage = _getMinPercent(pixelCount);
            } else {
                percentage = _rollPercentageFromEntropy(pixelCount, entropy, commitId, i);
            }
            totalActions += (pixelCount * percentage) / 100;
        }
        totalActions += commitment.transferredActionPoints;
        actionPoints[commitment.receiverTokenId] += totalActions;
        commitment.revealed = true;

        // Remove from owner's pending list (swap-and-pop)
        uint256[] storage pending = _userPendingCommitIds[commitment.owner];
        for (uint256 i; i < pending.length; i++) {
            if (pending[i] == commitId) {
                pending[i] = pending[pending.length - 1];
                pending.pop();
                break;
            }
        }

        emit BurnRevealed(commitId, commitment.owner, commitment.receiverTokenId, totalActions, expired);
    }

    /// @notice Returns the block number at which a commitment can be revealed
    function revealBlock(uint256 commitId) external view returns (uint256) {
        return burnCommitments[commitId].commitBlock + REVEAL_DELAY + 1;
    }

    /// @notice Returns the stored pixel counts for a commitment
    function commitPixelCounts(uint256 commitId) external view returns (uint256[] memory) {
        return burnCommitments[commitId].pixelCounts;
    }

    /// @notice Returns all unrevealed burn commitments for the given address
    function pendingBurnCommitments(address owner)
        external
        view
        returns (uint256[] memory commitIds, uint256[] memory receiverTokenIds)
    {
        uint256[] storage pending = _userPendingCommitIds[owner];
        commitIds = new uint256[](pending.length);
        receiverTokenIds = new uint256[](pending.length);
        for (uint256 i; i < pending.length; i++) {
            commitIds[i] = pending[i];
            receiverTokenIds[i] = burnCommitments[pending[i]].receiverTokenId;
        }
    }

    // ──────────────────────────────────────────────
    //  Transform
    // ──────────────────────────────────────────────

    /**
     * @notice Apply a pixel-level transform bitmap to a token's image.
     *         The bitmap is XOR-composited onto the original image to produce
     *         the transformed result. Each "on" bit in the bitmap consumes one
     *         action point, so the caller must have sufficient action points.
     *         On the first transform the original pixel count is snapshotted
     *         for later reference.
     * @dev Callable by the token owner or an authorized delegate.
     * @param tokenId The token to transform
     * @param bitmap  A 200-byte bitmap where each bit represents a pixel to flip.
     *                Must be exactly 200 bytes (1 600 pixels = 40 × 40 grid).
     * @custom:emits PixelsTransformed(transformer, tokenId, changeCount, newPixelCount)
     */
    function setTransformBitmap(uint256 tokenId, bytes calldata bitmap) external whenNotPaused nonReentrant {
        require(_isAuthorizedTransformer(tokenId, msg.sender), NotTokenOwnerOrDelegate());
        require(bitmap.length == 200, InvalidBitmapLength());

        uint256 pixelCount = _countPixels(bitmap);
        require(pixelCount <= actionPoints[tokenId], InsufficientTransformActions());

        bytes memory original = normiesStorage.getTokenRawImageData(tokenId);

        canvasStorage.setTransformedImageData(tokenId, bitmap);

        uint256 newPixelCount = _countPixels(_composite(original, bitmap));
        emit PixelsTransformed(msg.sender, tokenId, pixelCount, newPixelCount);
    }

    // ──────────────────────────────────────────────
    //  Delegation
    // ──────────────────────────────────────────────

    /// @notice Set a delegate who can transform pixels on a token you own (transforming only, not burning).
    function setDelegate(uint256 tokenId, address delegate) external {
        require(normies.ownerOf(tokenId) == msg.sender, NotTokenOwnerForDelegation());
        require(delegate != address(0), InvalidDelegate());
        delegates[tokenId] = delegate;
        delegateSetBy[tokenId] = msg.sender;
        emit DelegateSet(tokenId, delegate);
    }

    /// @notice Revoke the delegate for a token you own.
    function revokeDelegate(uint256 tokenId) external {
        require(normies.ownerOf(tokenId) == msg.sender, NotTokenOwnerForDelegation());
        address previous = delegates[tokenId];
        delete delegates[tokenId];
        delete delegateSetBy[tokenId];
        emit DelegateRevoked(tokenId, previous);
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setTransformStorage(INormiesCanvasStorage _transformStorage) external onlyOwner {
        canvasStorage = _transformStorage;
    }

    function setMaxBurnPercent(uint256 _maxBurnPercent) external onlyOwner {
        maxBurnPercent = _maxBurnPercent;
    }

    function setBurnTiers(uint256[2] calldata _thresholds, uint256[3] calldata _minPercents) external onlyOwner {
        tierThresholds = _thresholds;
        tierMinPercents = _minPercents;
    }

    // ──────────────────────────────────────────────
    //  Internal: Burn scaling
    // ──────────────────────────────────────────────

    /// @notice Returns the minimum burn percentage for a given pixel count (reads tierThresholds/tierMinPercents).
    function _getMinPercent(uint256 pixelCount) internal view returns (uint256) {
        if (pixelCount < tierThresholds[0]) return tierMinPercents[0];
        if (pixelCount < tierThresholds[1]) return tierMinPercents[1];
        return tierMinPercents[2];
    }

    /// @notice Rolls a random percentage in [minPercent, maxBurnPercent] using blockhash entropy from commit-reveal.
    function _rollPercentageFromEntropy(
        uint256 pixelCount,
        bytes32 entropy,
        uint256 commitId,
        uint256 index
    ) internal view returns (uint256) {
        uint256 minPercent = _getMinPercent(pixelCount);
        uint256 range = maxBurnPercent - minPercent + 1;
        if (range == 1) return minPercent;
        uint256 seed = uint256(keccak256(abi.encodePacked(entropy, commitId, index)));
        return minPercent + (seed % range);
    }

    // ──────────────────────────────────────────────
    //  Internal: Authorization
    // ──────────────────────────────────────────────

    /// @notice Returns true if the address is the token owner or its delegate (set by the current owner).
    function _isAuthorizedTransformer(uint256 tokenId, address transformer) internal view returns (bool) {
        address owner = normies.ownerOf(tokenId);
        if (owner == transformer) return true;
        return delegates[tokenId] == transformer && delegateSetBy[tokenId] == owner;
    }

    // ──────────────────────────────────────────────
    //  Internal: Bitmap helpers
    // ──────────────────────────────────────────────

    /// @notice Counts "on" pixels using Brian Kernighan's bit-counting algorithm
    function _countPixels(bytes memory imageData) internal pure returns (uint256 count) {
        for (uint256 i; i < 200; i++) {
            uint8 b = uint8(imageData[i]);
            while (b != 0) {
                b &= b - 1;
                count++;
            }
        }
    }

    /// @notice Composites two bitmaps via bitwise XOR (changes layer flips original pixels)
    function _composite(bytes memory base, bytes memory overlay) internal pure returns (bytes memory result) {
        result = new bytes(200);
        for (uint256 i; i < 200; i++) {
            result[i] = base[i] ^ overlay[i];
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesStorage } from "./interfaces/INormiesStorage.sol";
import { INormies } from "./interfaces/INormies.sol";
import { INormiesCanvasStorageV2 } from "./interfaces/INormiesCanvasStorageV2.sol";
import { INormiesCanvasV2 } from "./interfaces/INormiesCanvasV2.sol";
import { IDelegateRegistry } from "./interfaces/IDelegateRegistry.sol";
import { IDelegateRegistryV1 } from "./interfaces/IDelegateRegistryV1.sol";
import { INormiesZombie } from "./interfaces/INormiesZombie.sol";
import { NormiesBitmap } from "./NormiesBitmap.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";
import { ReentrancyGuardTransient } from "solady/utils/ReentrancyGuardTransient.sol";

/**
 * @title NormiesCanvasV2
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Burn Normies for pixels, paint with them, move them between a Normie and a wallet, and spend them on
 *         canvas services (enlargement, blank canvas), which burn them out of circulation.
 */
contract NormiesCanvasV2 is INormiesCanvasV2, Ownable, Lifebuoy, ReentrancyGuardTransient {
    struct BurnCommitment {
        address owner;
        uint256 receiverTokenId;
        uint64 commitBlock;
        uint16 tokenCount;
        bool revealed;
        /// @dev Reward and carried pixels go to the committer's wallet instead of a receiver token.
        bool toWallet;
        uint256 transferredActionPoints;
        uint256[] pixelCounts;
    }

    error NotTokenOwner();
    error NotTokenOwnerOrDelegate();
    error NotTokenOwnerForDelegation();
    error InvalidDelegate();
    error InsufficientTransformActions();
    error InvalidBitmapLength();
    error InvalidBitmapPadding();
    error Paused();
    error NoTokensProvided();
    error CannotBurnReceiver();
    error TooEarlyToReveal();
    error MigrationNotFinalized();
    error AlreadyRevealed();
    error CommitmentNotFound();
    error ZeroAmount();
    error OverlayExceedsBalance(uint256 overlayPixels, uint256 remaining);
    error InvalidGridSize(uint256 size);
    error GridNotLarger(uint256 current, uint256 requested);
    error BaseAlreadyCleared();
    error InvalidBurnTiers();
    error ZombieNotAllowed();

    /// @notice delegate.xyz registries. A wallet delegated there can paint and manage a Normie for its owner.
    IDelegateRegistry public constant DELEGATE_REGISTRY_V2 =
        IDelegateRegistry(0x00000000000000447e69651d841bD8D104Bed493);
    IDelegateRegistryV1 public constant DELEGATE_REGISTRY_V1 =
        IDelegateRegistryV1(0x00000000000076A84feF008CDAbe6409d2FE638B);

    /// @dev receiverTokenId is 0 and meaningless when toWallet is true.
    event BurnCommitted(
        uint256 indexed commitId,
        address indexed owner,
        uint256 indexed receiverTokenId,
        uint256 tokenCount,
        uint256 transferredActionPoints,
        bool toWallet
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
    event OverlayCleared(uint256 indexed tokenId, uint8 reason);
    event PixelsWithdrawn(uint256 indexed tokenId, address indexed to, uint256 amount, uint256 remainingAttached);
    event PixelsDeposited(uint256 indexed tokenId, address indexed from, uint256 amount, uint256 newAttached);
    event CanvasEnlarged(uint256 indexed tokenId, uint256 fromSize, uint256 toSize, uint256 cost, uint8 source);
    event BaseCleared(uint256 indexed tokenId, uint256 cost, uint8 source);
    event PausedSet(bool paused);
    event EnlargePriceSet(uint256 size, uint256 cumulativeCost);
    event BlankCanvasPriceSet(uint256 price);
    event MaxBurnPercentSet(uint256 maxBurnPercent);
    event BurnTiersSet(uint256[] thresholds, uint256[] minPercents);

    IERC721 public immutable normies;
    INormiesStorage public immutable normiesStorage;

    INormiesCanvasStorageV2 public canvasStorage;
    INormiesZombie public zombieContract;

    /// @notice Cumulative price of each grid size relative to 40x40 (50 -> 900, 60 -> 2000, 70 -> 3300, 80 -> 4800).
    mapping(uint256 => uint256) public enlargePrice;
    /// @notice Price of turning the base art off.
    uint256 public blankCanvasPrice = 200;

    mapping(uint256 => BurnCommitment) public burnCommitments;
    mapping(address => uint256[]) private _userPendingCommitIds;
    uint256 public nextCommitId;

    uint256 public constant REVEAL_DELAY = 5;
    uint256 public maxBurnPercent = 4;
    /// @notice Burn tiers: a token with fewer pixels than tierThresholds[i] rolls at least tierMinPercents[i]; one at or
    ///         above the last threshold rolls at least the last minimum. Any number of tiers.
    uint256[] public tierThresholds = [uint256(490), 890];
    uint256[] public tierMinPercents = [uint256(1), 2, 3];

    /// @notice Starts paused; unpausing needs storage V2's migration and delegation copies to be finalized.
    bool public paused = true;

    constructor(
        address _normies,
        INormiesStorage _originalStorage,
        INormiesCanvasStorageV2 _canvasStorage
    ) Ownable() Lifebuoy() {
        normies = IERC721(_normies);
        normiesStorage = _originalStorage;
        canvasStorage = _canvasStorage;
        enlargePrice[50] = 900;
        enlargePrice[60] = 2000;
        enlargePrice[70] = 3300;
        enlargePrice[80] = 4800;
    }

    modifier whenNotPaused() {
        require(!paused, Paused());
        _;
    }

    // ──────────────────────────────────────────────
    //  INormiesCanvas compatibility
    // ──────────────────────────────────────────────

    function actionPoints(uint256 tokenId) external view returns (uint256) {
        return canvasStorage.attachedOf(tokenId);
    }

    function getLevel(uint256 tokenId) external view returns (uint256) {
        return canvasStorage.attachedOf(tokenId) / 10 + 1;
    }

    /// @notice Per-token state lives in storage V2; these views read it through for the site and older callers.
    function gridSize(uint256 tokenId) public view returns (uint256) {
        return canvasStorage.gridSize(tokenId);
    }

    function baseCleared(uint256 tokenId) public view returns (bool) {
        return canvasStorage.baseCleared(tokenId);
    }

    function delegates(uint256 tokenId) external view returns (address) {
        return canvasStorage.delegates(tokenId);
    }

    function delegateSetBy(uint256 tokenId) external view returns (address) {
        return canvasStorage.delegateSetBy(tokenId);
    }

    /// @notice Pixels currently locked by the overlay (its "on" bits). Zero when the token is not transformed.
    function lockedPixels(uint256 tokenId) public view returns (uint256) {
        return _overlayPixels(tokenId, gridSize(tokenId));
    }

    /// @notice A token's delegate and the owner who set it. The delegate only counts while that owner still holds it.
    function effectiveDelegate(uint256 tokenId) external view returns (address delegate, address setBy) {
        return canvasStorage.delegation(tokenId);
    }

    // ──────────────────────────────────────────────
    //  Burn: Commit-Reveal
    // ──────────────────────────────────────────────

    /**
     * @notice Phase 1: Burn Normies and commit pixel counts. Tokens are burned immediately; pixels already attached
     *         to them move to the receiver right away, the rolled reward is credited on reveal.
     */
    function commitBurn(uint256[] calldata tokenIds, uint256 receiverTokenId) external whenNotPaused nonReentrant {
        _requireOwner(receiverTokenId);
        _commitBurn(tokenIds, receiverTokenId, false);
    }

    /**
     * @notice Phase 1, wallet variant: burn Normies without naming a receiver. Pixels already attached to them land
     *         in the caller's wallet balance right away and the rolled reward is minted there on reveal, so the
     *         result can be listed on the market or deposited later.
     */
    function commitBurnToWallet(uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        _commitBurn(tokenIds, 0, true);
    }

    function _commitBurn(uint256[] calldata tokenIds, uint256 receiverTokenId, bool toWallet) internal {
        require(tokenIds.length > 0, NoTokensProvided());

        uint256 commitId = nextCommitId++;
        BurnCommitment storage commitment = burnCommitments[commitId];
        commitment.owner = msg.sender;
        commitment.receiverTokenId = receiverTokenId;
        commitment.commitBlock = uint64(block.number);
        commitment.tokenCount = uint16(tokenIds.length);
        commitment.toWallet = toWallet;

        uint256 transferred;
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            _requireOwner(tokenId);
            require(toWallet || tokenId != receiverTokenId, CannotBurnReceiver());

            bytes memory bitmap = normiesStorage.getTokenRawImageData(tokenId);
            commitment.pixelCounts.push(NormiesBitmap.countPixels(bitmap, NormiesBitmap.BASE_GRID));

            uint256 ap = canvasStorage.attachedOf(tokenId);
            if (ap > 0) {
                if (toWallet) {
                    canvasStorage.detach(tokenId, msg.sender, ap, INormiesCanvasStorageV2.Reason.BurnTransfer);
                } else {
                    canvasStorage.moveAttached(
                        tokenId, receiverTokenId, ap, INormiesCanvasStorageV2.Reason.BurnTransfer
                    );
                }
                transferred += ap;
            }

            _resetTokenState(tokenId);
            INormies(address(normies)).burn(tokenId);
        }
        commitment.transferredActionPoints = transferred;
        _userPendingCommitIds[msg.sender].push(commitId);

        emit BurnCommitted(commitId, msg.sender, receiverTokenId, tokenIds.length, transferred, toWallet);
    }

    /**
     * @notice Phase 2: Reveal a burn commitment after REVEAL_DELAY blocks to credit pixels.
     *         Uses blockhash of (commitBlock + REVEAL_DELAY) as entropy for the percentage roll.
     *         If the reveal window has expired (>256 blocks), falls back to minimum tier percentages.
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
            uint256 minPercent = _getMinPercent(pixelCount);
            uint256 percentage =
                expired ? minPercent : _rollPercentage(minPercent, maxBurnPercent, entropy, commitId, i);
            totalActions += (pixelCount * percentage) / 100;
        }
        commitment.revealed = true;
        if (commitment.toWallet) {
            if (totalActions > 0) canvasStorage.mintTo(commitment.owner, totalActions);
        } else {
            _creditReward(commitment.receiverTokenId, commitment.owner, totalActions);
        }

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

    /// @notice Returns all unrevealed burn commitments for the given address. receiverTokenIds[i] is meaningless
    ///         when toWallet[i] is true.
    function pendingBurnCommitments(address owner)
        external
        view
        returns (uint256[] memory commitIds, uint256[] memory receiverTokenIds, bool[] memory toWallet)
    {
        uint256[] storage pending = _userPendingCommitIds[owner];
        commitIds = new uint256[](pending.length);
        receiverTokenIds = new uint256[](pending.length);
        toWallet = new bool[](pending.length);
        for (uint256 i; i < pending.length; i++) {
            BurnCommitment storage commitment = burnCommitments[pending[i]];
            commitIds[i] = pending[i];
            receiverTokenIds[i] = commitment.receiverTokenId;
            toWallet[i] = commitment.toWallet;
        }
    }

    // ──────────────────────────────────────────────
    //  Transform
    // ──────────────────────────────────────────────

    /**
     * @notice Apply an overlay bitmap to a token. The overlay is XOR-composited onto the base art. Its "on" bit
     *         count may not exceed the pixels attached to the token. Length must match the token's grid size and
     *         padding bits must be zero.
     * @dev Callable by the token owner or an authorized delegate.
     */
    function setTransformBitmap(uint256 tokenId, bytes calldata bitmap) external whenNotPaused nonReentrant {
        require(_isAuthorizedTransformer(tokenId, msg.sender), NotTokenOwnerOrDelegate());
        uint256 size = gridSize(tokenId);
        require(bitmap.length == NormiesBitmap.bytesForGrid(size), InvalidBitmapLength());
        require(NormiesBitmap.hasCleanPadding(bitmap, size), InvalidBitmapPadding());

        uint256 pixelCount = NormiesBitmap.countPixels(bitmap, size);
        require(pixelCount <= canvasStorage.attachedOf(tokenId), InsufficientTransformActions());

        canvasStorage.setTransformedImageData(tokenId, bitmap);

        uint256 newPixelCount =
            NormiesBitmap.countPixels(NormiesBitmap.composite(_baseBitmap(tokenId, size), bitmap), size);
        emit PixelsTransformed(msg.sender, tokenId, pixelCount, newPixelCount);
    }

    // ──────────────────────────────────────────────
    //  Pixel moves
    // ──────────────────────────────────────────────

    /**
     * @notice Move pixels from a token you own into your wallet balance.
     * @param clearOverlay Must be true when the remaining attached pixels no longer cover the overlay; the overlay
     *                     is then reset to the base art. Reverts with OverlayExceedsBalance otherwise.
     */
    function withdrawPixels(uint256 tokenId, uint256 amount, bool clearOverlay) external whenNotPaused nonReentrant {
        _requireOwner(tokenId);
        address owner = msg.sender;
        require(amount > 0, ZeroAmount());
        canvasStorage.detach(tokenId, owner, amount, INormiesCanvasStorageV2.Reason.Withdraw);
        _enforceCeiling(tokenId, clearOverlay, ClearReason.Withdraw);
        emit PixelsWithdrawn(tokenId, owner, amount, canvasStorage.attachedOf(tokenId));
    }

    /**
     * @notice Move pixels from a token owner's wallet balance onto that token.
     * @dev Callable by the owner, or by a wallet the owner approved for the amount; the pixels always come from
     *      the owner's wallet. Depositing onto someone else's Normie is refused, so pixels only change hands
     *      through the market.
     */
    function depositPixels(uint256 tokenId, uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, ZeroAmount());
        address owner = _requireOwnerOrApproved(tokenId, amount);
        canvasStorage.attach(owner, tokenId, amount, INormiesCanvasStorageV2.Reason.Deposit);
        emit PixelsDeposited(tokenId, owner, amount, canvasStorage.attachedOf(tokenId));
    }

    // ──────────────────────────────────────────────
    //  Canvas services
    // ──────────────────────────────────────────────

    /**
     * @notice Enlarge a token's canvas to 50, 60, 70 or 80 pixels per side. The base art stays centred, an existing
     *         overlay is re-embedded, and the price is the difference between the cumulative tier prices.
     * @param source Wallet pays from the owner's wallet balance; Attached pays from the token's attached pixels
     *               (subject to the ceiling rule, see withdrawPixels). Either way a caller other than the owner
     *               needs an allowance from the owner for the cost.
     */
    function enlargeCanvas(
        uint256 tokenId,
        uint256 newSize,
        PaySource source,
        bool clearOverlay
    ) external whenNotPaused nonReentrant {
        require(_isEnlargedGrid(newSize), InvalidGridSize(newSize));
        uint256 current = gridSize(tokenId);
        require(newSize > current, GridNotLarger(current, newSize));

        uint256 cost = enlargePrice[newSize] - enlargePrice[current];
        address owner = _requireOwnerOrApproved(tokenId, cost);
        _pay(owner, tokenId, cost, source, clearOverlay);

        if (canvasStorage.isTransformed(tokenId)) {
            bytes memory overlay = canvasStorage.getTransformedImageData(tokenId);
            if (overlay.length == NormiesBitmap.bytesForGrid(current)) {
                canvasStorage.setTransformedImageData(tokenId, NormiesBitmap.embedCentered(overlay, current, newSize));
            } else {
                canvasStorage.clearTransformedImageData(tokenId);
                emit OverlayCleared(tokenId, uint8(ClearReason.Spend));
            }
        }
        canvasStorage.setGridSize(tokenId, newSize);

        emit CanvasEnlarged(tokenId, current, newSize, cost, uint8(source));
    }

    /// @notice Turn the base art of a human Normie off for good. Painting still needs attached pixels.
    function clearBase(uint256 tokenId, PaySource source, bool clearOverlay) external whenNotPaused nonReentrant {
        require(!canvasStorage.baseCleared(tokenId), BaseAlreadyCleared());
        require(!_isZombie(tokenId), ZombieNotAllowed());

        uint256 cost = blankCanvasPrice;
        address owner = _requireOwnerOrApproved(tokenId, cost);
        _pay(owner, tokenId, cost, source, clearOverlay);
        canvasStorage.setBaseCleared(tokenId, true);

        emit BaseCleared(tokenId, cost, uint8(source));
    }

    // ──────────────────────────────────────────────
    //  Delegation
    // ──────────────────────────────────────────────

    /// @notice Set a delegate who can paint on a token you own (painting only, no burning or pixel moves).
    function setDelegate(uint256 tokenId, address delegate) external {
        _requireOwnerForDelegation(tokenId);
        require(delegate != address(0), InvalidDelegate());
        canvasStorage.setDelegate(tokenId, delegate, msg.sender);
    }

    /// @notice Revoke the delegate for a token you own.
    function revokeDelegate(uint256 tokenId) external {
        _requireOwnerForDelegation(tokenId);
        canvasStorage.setDelegate(tokenId, address(0), address(0));
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    function setPaused(bool _paused) external onlyOwner {
        if (!_paused) {
            require(canvasStorage.migrationFinalized() && canvasStorage.delegationsSeeded(), MigrationNotFinalized());
        }
        paused = _paused;
        emit PausedSet(_paused);
    }

    function setCanvasStorage(INormiesCanvasStorageV2 _canvasStorage) external onlyOwner {
        canvasStorage = _canvasStorage;
    }

    function setZombieContract(INormiesZombie _zombie) external onlyOwner {
        zombieContract = _zombie;
    }

    function setEnlargePrice(uint256 size, uint256 cumulativeCost) external onlyOwner {
        require(_isEnlargedGrid(size), InvalidGridSize(size));
        enlargePrice[size] = cumulativeCost;
        emit EnlargePriceSet(size, cumulativeCost);
    }

    function setBlankCanvasPrice(uint256 price) external onlyOwner {
        blankCanvasPrice = price;
        emit BlankCanvasPriceSet(price);
    }

    /// @notice The tier tables in one call.
    function burnTiers() external view returns (uint256[] memory thresholds, uint256[] memory minPercents) {
        return (tierThresholds, tierMinPercents);
    }

    /// @dev At most 100, and never below the top tier's minimum, or every roll would underflow.
    function setMaxBurnPercent(uint256 _maxBurnPercent) external onlyOwner {
        require(
            _maxBurnPercent <= 100 && _maxBurnPercent >= tierMinPercents[tierMinPercents.length - 1], InvalidBurnTiers()
        );
        maxBurnPercent = _maxBurnPercent;
        emit MaxBurnPercentSet(_maxBurnPercent);
    }

    /**
     * @notice Replaces the tier tables. `_minPercents` has one more entry than `_thresholds`: thresholds strictly
     *         ascending, minimums non-decreasing and none above maxBurnPercent. Any number of tiers, at least one.
     */
    function setBurnTiers(uint256[] calldata _thresholds, uint256[] calldata _minPercents) external onlyOwner {
        require(_minPercents.length == _thresholds.length + 1, InvalidBurnTiers());
        for (uint256 i; i < _thresholds.length; i++) {
            require(i == 0 || _thresholds[i] > _thresholds[i - 1], InvalidBurnTiers());
        }
        for (uint256 i; i < _minPercents.length; i++) {
            require(i == 0 || _minPercents[i] >= _minPercents[i - 1], InvalidBurnTiers());
        }
        require(_minPercents[_minPercents.length - 1] <= maxBurnPercent, InvalidBurnTiers());
        tierThresholds = _thresholds;
        tierMinPercents = _minPercents;
        emit BurnTiersSet(_thresholds, _minPercents);
    }

    // ──────────────────────────────────────────────
    //  Internal: burn scaling
    // ──────────────────────────────────────────────

    function _getMinPercent(uint256 pixelCount) internal view returns (uint256) {
        uint256 tiers = tierThresholds.length;
        for (uint256 i; i < tiers; i++) {
            if (pixelCount < tierThresholds[i]) return tierMinPercents[i];
        }
        return tierMinPercents[tiers];
    }

    /// @notice Rolls a percentage in [minPercent, maxPercent] from commit-reveal entropy (same formula as V1).
    function _rollPercentage(
        uint256 minPercent,
        uint256 maxPercent,
        bytes32 entropy,
        uint256 commitId,
        uint256 index
    ) internal pure returns (uint256) {
        uint256 range = maxPercent - minPercent + 1;
        if (range == 1) return minPercent;
        uint256 seed = uint256(keccak256(abi.encodePacked(entropy, commitId, index)));
        return minPercent + (seed % range);
    }

    /// @dev One copy of the owner check keeps the runtime bytecode under the 24576-byte limit.
    function _requireOwner(uint256 tokenId) internal view {
        require(normies.ownerOf(tokenId) == msg.sender, NotTokenOwner());
    }

    /**
     * @dev The token's owner, or a wallet the owner approved for at least `amount` pixels
     *      (NormiesCanvasStorageV2.approve). Returns the owner: an approved wallet acts on the owner's pixels and
     *      its allowance is consumed here, so nothing it does can leave the owner's wallet or the owner's token
     *      except as the owner priced it. A delegation of any kind, Canvas or delegate.xyz, grants painting only
     *      and does not pass this check.
     */
    function _requireOwnerOrApproved(uint256 tokenId, uint256 amount) internal returns (address owner) {
        owner = normies.ownerOf(tokenId);
        if (owner == msg.sender) return owner;
        require(amount > 0, NotTokenOwner());
        canvasStorage.useAllowance(owner, msg.sender, amount);
    }

    /// @dev delegate.xyz (either registry; a token, contract or wallet level delegation): painting rights only.
    function _isVaultDelegate(address owner, address delegate, uint256 tokenId) internal view returns (bool) {
        return DELEGATE_REGISTRY_V2.checkDelegateForERC721(delegate, owner, address(normies), tokenId, "")
            || DELEGATE_REGISTRY_V1.checkDelegateForToken(delegate, owner, address(normies), tokenId);
    }

    function _requireOwnerForDelegation(uint256 tokenId) internal view {
        require(normies.ownerOf(tokenId) == msg.sender, NotTokenOwnerForDelegation());
    }

    /// @dev Credits a reward to the receiver token, or to the committer's wallet if the receiver no longer exists.
    function _creditReward(uint256 receiverTokenId, address committer, uint256 amount) internal {
        if (amount == 0) return;
        try normies.ownerOf(receiverTokenId) returns (address) {
            canvasStorage.creditAttached(receiverTokenId, amount, INormiesCanvasStorageV2.Reason.BurnReward);
        } catch {
            canvasStorage.mintTo(committer, amount);
        }
    }

    // ──────────────────────────────────────────────
    //  Internal: pixels and ceiling
    // ──────────────────────────────────────────────

    /// @dev Pixels spent on a service leave circulation for good: nobody is credited, supply shrinks. Whether they
    ///      come from the owner's wallet or from the token, spending them needs the owner, or an allowance from the
    ///      owner to the caller; a delegation alone never spends anything.
    function _pay(address owner, uint256 tokenId, uint256 cost, PaySource source, bool clearOverlay) internal {
        if (cost == 0) return;
        if (source == PaySource.Wallet) {
            canvasStorage.burnFrom(owner, cost);
        } else {
            canvasStorage.debitAttached(tokenId, cost, INormiesCanvasStorageV2.Reason.Spend);
            _enforceCeiling(tokenId, clearOverlay, ClearReason.Spend);
        }
    }

    /// @dev After attached pixels went down: clear the overlay if it is no longer covered, with acknowledgement.
    function _enforceCeiling(uint256 tokenId, bool clearOverlay, ClearReason reason) internal {
        uint256 locked = _overlayPixels(tokenId, gridSize(tokenId));
        if (locked == 0) return;
        uint256 remaining = canvasStorage.attachedOf(tokenId);
        if (locked <= remaining) return;
        require(clearOverlay, OverlayExceedsBalance(locked, remaining));
        canvasStorage.clearTransformedImageData(tokenId);
        emit OverlayCleared(tokenId, uint8(reason));
    }

    function _overlayPixels(uint256 tokenId, uint256 size) internal view returns (uint256) {
        if (!canvasStorage.isTransformed(tokenId)) return 0;
        bytes memory overlay = canvasStorage.getTransformedImageData(tokenId);
        if (overlay.length == NormiesBitmap.bytesForGrid(size)) return NormiesBitmap.countPixels(overlay, size);
        return NormiesBitmap.countBits(overlay);
    }

    /// @dev The art the overlay is composited onto, already embedded into the token's grid.
    function _baseBitmap(uint256 tokenId, uint256 size) internal view returns (bytes memory) {
        if (canvasStorage.baseCleared(tokenId)) return NormiesBitmap.empty(size);
        bytes memory raw =
            _isZombie(tokenId) ? zombieContract.getZombieBitmap(tokenId) : normiesStorage.getTokenRawImageData(tokenId);
        return NormiesBitmap.embedCentered(raw, NormiesBitmap.BASE_GRID, size);
    }

    function _isZombie(uint256 tokenId) internal view returns (bool) {
        return address(zombieContract) != address(0) && zombieContract.isZombie(tokenId);
    }

    function _isEnlargedGrid(uint256 size) internal pure returns (bool) {
        return size == 50 || size == 60 || size == 70 || size == 80;
    }

    /// @dev Burned ids can be minted again, so per-token canvas state must not survive a burn.
    function _resetTokenState(uint256 tokenId) internal {
        canvasStorage.resetTokenState(tokenId);
    }

    // ──────────────────────────────────────────────
    //  Internal: authorization
    // ──────────────────────────────────────────────

    function _isAuthorizedTransformer(uint256 tokenId, address transformer) internal view returns (bool) {
        address owner = normies.ownerOf(tokenId);
        if (owner == transformer) return true;
        (address delegate, address setBy) = canvasStorage.delegation(tokenId);
        if (delegate == transformer && setBy == owner) return true;
        return _isVaultDelegate(owner, transformer, tokenId);
    }
}

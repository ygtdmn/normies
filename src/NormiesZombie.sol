// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesStorage } from "./interfaces/INormiesStorage.sol";
import { INormiesCanvas } from "./interfaces/INormiesCanvas.sol";
import { INormiesZombieStorage } from "./interfaces/INormiesZombieStorage.sol";
import { IDelegateRegistry } from "./interfaces/IDelegateRegistry.sol";
import { IDelegateRegistryV1 } from "./interfaces/IDelegateRegistryV1.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";
import { ReentrancyGuardTransient } from "solady/utils/ReentrancyGuardTransient.sol";

/**
 * @title NormiesZombie
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @dev Merkle-gated in-place conversion orchestrator for bespoke zombie Normies.
 */
contract NormiesZombie is Ownable, Lifebuoy, ReentrancyGuardTransient {
    struct ConversionCommitment {
        address qualifyingWallet; // the merkle-whitelisted wallet that owns the claim slot
        address committer; // the address that submitted the commit (wallet itself or its delegate)
        address committedOwner; // token owner at commit time; reveal aborts if ownership changed since
        uint256 tokenId;
        uint256 index; // claim slot / merkle leaf index, also indexes into the shuffled permutation
        uint64 commitBlock;
        bool revealed;
        bool cancelled;
    }

    IDelegateRegistry public constant DELEGATE_REGISTRY_V2 =
        IDelegateRegistry(0x00000000000000447e69651d841bD8D104Bed493);
    IDelegateRegistryV1 public constant DELEGATE_REGISTRY_V1 =
        IDelegateRegistryV1(0x00000000000076A84feF008CDAbe6409d2FE638B);

    uint256 public constant CLAIM_COUNT = 21; // number of whitelisted claim slots (merkle leaves 0..20)
    uint256 public constant REVEAL_DELAY = 5; // blocks that must pass after commit before reveal is allowed
    uint256 public constant CANCEL_DELAY = 7200; // blocks (~1 day) after which anyone may cancel a stuck commit

    IERC721 public immutable normies;
    INormiesStorage public immutable normiesStorage;
    INormiesCanvas public immutable canvas;
    INormiesZombieStorage public immutable zombieStorage;

    bytes32 public merkleRoot;
    uint256 public seedBlock;
    bytes32 public seed;
    bool public seedLocked;
    bool public paused = true;

    mapping(address => bool) public hasClaimed;
    mapping(uint256 => bool) public tokenLocked;
    mapping(uint256 => ConversionCommitment) public commitments;
    mapping(address => uint256) public pendingCommit;
    uint256[] private _permutation;
    uint256 public nextCommitId = 1;

    error Paused();
    error InvalidMerkleProof();
    error NotQualifyingWalletOrDelegate();
    error InvalidVault();
    error AlreadyClaimed(address qualifyingWallet);
    error TokenLocked(uint256 tokenId);
    error AlreadyZombie(uint256 tokenId);
    error TokenNotControlledByWallet(uint256 tokenId, address qualifyingWallet);
    error NotHuman(uint256 tokenId);
    error NotLevelOne(uint256 tokenId);
    error CommitmentNotFound(uint256 commitId);
    error TooEarlyToReveal(uint256 commitId);
    error SeedBlockNotSet();
    error SeedBlockNotReady(uint256 seedBlock);
    error SeedAlreadyLocked();
    error SeedNotLocked();
    error PoolNotReady(uint256 poolSize);
    error OwnershipChanged(uint256 tokenId);
    error AlreadyFinalized(uint256 commitId);
    error NotCommitterOrOwner();
    error CancelDelayNotElapsed(uint256 commitId);

    event MerkleRootSet(bytes32 merkleRoot);
    event SeedBlockSet(uint256 seedBlock);
    event SeedLocked(bytes32 seed, uint256 poolSize);
    event PausedSet(bool paused);
    event ZombieConvertCommitted(
        uint256 indexed commitId,
        address indexed qualifyingWallet,
        uint256 indexed tokenId,
        uint256 index,
        address committer,
        address committedOwner
    );
    event ZombieConverted(
        uint256 indexed commitId, uint256 indexed tokenId, address indexed qualifyingWallet, uint256 poolIndex
    );
    event ZombieCommitCancelled(uint256 indexed commitId, address indexed qualifyingWallet, uint256 indexed tokenId);

    constructor(
        address _normies,
        INormiesStorage _normiesStorage,
        INormiesCanvas _canvas,
        INormiesZombieStorage _zombieStorage
    ) Ownable() Lifebuoy() {
        normies = IERC721(_normies);
        normiesStorage = _normiesStorage;
        canvas = _canvas;
        zombieStorage = _zombieStorage;
    }

    modifier whenNotPaused() {
        require(!paused, Paused());
        _;
    }

    function commitConvert(
        uint256 tokenId,
        uint256 index,
        address qualifyingWallet,
        bytes32[] calldata proof,
        address vault
    ) external whenNotPaused nonReentrant returns (uint256 commitId) {
        require(_verify(index, qualifyingWallet, proof), InvalidMerkleProof());
        require(vault == address(0) || vault == qualifyingWallet, InvalidVault());

        // When called by someone other than the qualifying wallet, the caller must be a
        // delegate.xyz delegate of that wallet (which must be passed as the vault).
        if (msg.sender != qualifyingWallet) {
            require(vault == qualifyingWallet, InvalidVault());
            require(_isDelegate(msg.sender, qualifyingWallet), NotQualifyingWalletOrDelegate());
        }

        require(!hasClaimed[qualifyingWallet], AlreadyClaimed(qualifyingWallet));
        require(!tokenLocked[tokenId], TokenLocked(tokenId));
        require(!zombieStorage.isZombie(tokenId), AlreadyZombie(tokenId));

        // Token must be controlled by the qualifying wallet (held by it directly, or by the
        // delegate caller acting on its behalf).
        address tokenOwner = normies.ownerOf(tokenId);
        require(
            tokenOwner == qualifyingWallet || tokenOwner == msg.sender,
            TokenNotControlledByWallet(tokenId, qualifyingWallet)
        );

        // Only an un-leveled human Normie is eligible: traits[0] == 0 marks the human type,
        // and level 1 means it has not been edited via the canvas.
        bytes8 traits = normiesStorage.getTokenTraits(tokenId);
        require(uint8(traits[0]) == 0, NotHuman(tokenId));
        require(canvas.getLevel(tokenId) == 1, NotLevelOne(tokenId));

        commitId = nextCommitId++;
        commitments[commitId] = ConversionCommitment({
            qualifyingWallet: qualifyingWallet,
            committer: msg.sender,
            committedOwner: tokenOwner,
            tokenId: tokenId,
            index: index,
            commitBlock: uint64(block.number),
            revealed: false,
            cancelled: false
        });
        pendingCommit[qualifyingWallet] = commitId;
        hasClaimed[qualifyingWallet] = true;
        tokenLocked[tokenId] = true;

        emit ZombieConvertCommitted(commitId, qualifyingWallet, tokenId, index, msg.sender, tokenOwner);
    }

    function revealConvert(uint256 commitId) external whenNotPaused nonReentrant {
        ConversionCommitment storage commitment = commitments[commitId];
        require(commitment.commitBlock != 0, CommitmentNotFound(commitId));
        require(!commitment.revealed && !commitment.cancelled, AlreadyFinalized(commitId));
        require(block.number > commitment.commitBlock + REVEAL_DELAY, TooEarlyToReveal(commitId));
        require(seedLocked, SeedNotLocked());
        require(normies.ownerOf(commitment.tokenId) == commitment.committedOwner, OwnershipChanged(commitment.tokenId));
        require(!zombieStorage.isZombie(commitment.tokenId), AlreadyZombie(commitment.tokenId));

        // The claim slot index maps to a shuffled pool asset via the locked permutation,
        // so which zombie a wallet gets is unknown at commit time.
        uint256 poolIndex = _permutation[commitment.index];
        commitment.revealed = true;
        tokenLocked[commitment.tokenId] = false;
        pendingCommit[commitment.qualifyingWallet] = 0;

        zombieStorage.setZombie(commitment.tokenId, poolIndex);
        emit ZombieConverted(commitId, commitment.tokenId, commitment.qualifyingWallet, poolIndex);
    }

    function cancelCommit(uint256 commitId) external nonReentrant {
        ConversionCommitment storage commitment = commitments[commitId];
        require(commitment.commitBlock != 0, CommitmentNotFound(commitId));
        require(!commitment.revealed && !commitment.cancelled, AlreadyFinalized(commitId));

        // Owner and the original committer can cancel immediately; anyone else must wait out
        // CANCEL_DELAY so a stuck commit can always be unwound and the token/slot freed.
        bool allowed = msg.sender == owner() || msg.sender == commitment.committer;
        if (!allowed) {
            require(block.number > commitment.commitBlock + CANCEL_DELAY, CancelDelayNotElapsed(commitId));
        }

        commitment.cancelled = true;
        hasClaimed[commitment.qualifyingWallet] = false;
        tokenLocked[commitment.tokenId] = false;
        pendingCommit[commitment.qualifyingWallet] = 0;

        emit ZombieCommitCancelled(commitId, commitment.qualifyingWallet, commitment.tokenId);
    }

    function lockSeed() external {
        require(!seedLocked, SeedAlreadyLocked());
        require(seedBlock != 0, SeedBlockNotSet());
        require(block.number > seedBlock, SeedBlockNotReady(seedBlock));

        uint256 size = zombieStorage.poolSize();
        require(zombieStorage.isPoolSealed() && size >= CLAIM_COUNT, PoolNotReady(size));

        // blockhash() returns 0 for blocks older than 256 or not yet mined; fall back to a
        // deterministic value so the seed can still be locked (at the cost of randomness).
        bytes32 lockedSeed = blockhash(seedBlock);
        if (lockedSeed == bytes32(0)) {
            lockedSeed = keccak256(abi.encodePacked(block.chainid, address(this), seedBlock));
        }

        seed = lockedSeed;
        seedLocked = true;

        // Fisher-Yates shuffle of [0, size): each step picks j in [i, size) from the seed and
        // swaps, producing an unbiased permutation that maps claim slots to pool assets.
        uint256[] memory permutation = new uint256[](size);
        for (uint256 i; i < size; i++) {
            permutation[i] = i;
        }
        for (uint256 i; i < size; i++) {
            uint256 j = i + (uint256(keccak256(abi.encodePacked(lockedSeed, i))) % (size - i));
            uint256 tmp = permutation[i];
            permutation[i] = permutation[j];
            permutation[j] = tmp;
        }

        delete _permutation;
        for (uint256 i; i < size; i++) {
            _permutation.push(permutation[i]);
        }

        emit SeedLocked(lockedSeed, size);
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
        emit MerkleRootSet(_merkleRoot);
    }

    function setSeedBlock(uint256 _seedBlock) external onlyOwner {
        require(!seedLocked, SeedAlreadyLocked());
        seedBlock = _seedBlock;
        emit SeedBlockSet(_seedBlock);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function isZombie(uint256 tokenId) external view returns (bool) {
        return zombieStorage.isZombie(tokenId);
    }

    function getZombieBitmap(uint256 tokenId) external view returns (bytes memory) {
        return zombieStorage.getZombieBitmap(tokenId);
    }

    function getZombieAttributes(uint256 tokenId) external view returns (bytes memory) {
        return zombieStorage.getZombieAttributes(tokenId);
    }

    function revealBlock(uint256 commitId) external view returns (uint256) {
        ConversionCommitment storage commitment = commitments[commitId];
        require(commitment.commitBlock != 0, CommitmentNotFound(commitId));
        return commitment.commitBlock + REVEAL_DELAY + 1;
    }

    function permutationLength() external view returns (uint256) {
        return _permutation.length;
    }

    function assignedPoolIndex(uint256 index) external view returns (uint256) {
        require(seedLocked, SeedNotLocked());
        require(index < CLAIM_COUNT, InvalidMerkleProof());
        return _permutation[index];
    }

    /// @dev Double-hashed leaf, matching OpenZeppelin's standard (and merkletreejs) convention
    ///      to harden against second-preimage attacks on the tree.
    function leafHash(uint256 index, address qualifyingWallet) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, qualifyingWallet))));
    }

    function _verify(uint256 index, address qualifyingWallet, bytes32[] calldata proof) internal view returns (bool) {
        if (index >= CLAIM_COUNT) return false;
        return MerkleProof.verify(proof, merkleRoot, leafHash(index, qualifyingWallet));
    }

    /// @dev True if `delegate` is authorized for `vault` either wallet-wide or for the Normies
    ///      contract specifically, across both v2 and v1 delegate.xyz registries.
    function _isDelegate(address delegate, address vault) internal view returns (bool) {
        return DELEGATE_REGISTRY_V2.checkDelegateForAll(delegate, vault, bytes32(0))
            || DELEGATE_REGISTRY_V2.checkDelegateForContract(delegate, vault, address(normies), bytes32(0))
            || DELEGATE_REGISTRY_V1.checkDelegateForAll(delegate, vault)
            || DELEGATE_REGISTRY_V1.checkDelegateForContract(delegate, vault, address(normies));
    }
}

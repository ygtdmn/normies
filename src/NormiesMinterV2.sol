// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormies } from "./interfaces/INormies.sol";
import { INormiesStorage } from "./interfaces/INormiesStorage.sol";
import { IDelegateRegistry } from "./interfaces/IDelegateRegistry.sol";
import { IDelegateRegistryV1 } from "./interfaces/IDelegateRegistryV1.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesMinterV2
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @dev Added Delegate.xyz v1 support
 */
contract NormiesMinterV2 is Ownable, Lifebuoy {
    IDelegateRegistry public constant DELEGATE_REGISTRY_V2 =
        IDelegateRegistry(0x00000000000000447e69651d841bD8D104Bed493);
    IDelegateRegistryV1 public constant DELEGATE_REGISTRY_V1 =
        IDelegateRegistryV1(0x00000000000076A84feF008CDAbe6409d2FE638B);

    INormies public normies;
    INormiesStorage public normiesStorage;
    address public signer;
    address public withdrawAddress;
    uint256 public mintPrice;
    uint256 public nextTokenId;
    bool public paused;

    /// @notice Number of tokens minted per wallet address
    mapping(address => uint256) public mintCount;

    error InvalidSignature();
    error InsufficientPayment();
    error MintLimitReached();
    error NotMinterOrDelegate();
    error WithdrawFailed();
    error ArrayLengthMismatch();
    error SignatureExpired();
    error MintingPaused();

    event Mint(address indexed minter, uint256 indexed tokenId, bytes imageData, bytes8 traits);

    constructor(
        INormies _normies,
        INormiesStorage _normiesStorage,
        address _signer,
        uint256 _mintPrice,
        address _withdrawAddress
    ) Ownable() Lifebuoy() {
        normies = _normies;
        normiesStorage = _normiesStorage;
        signer = _signer;
        mintPrice = _mintPrice;
        withdrawAddress = _withdrawAddress;
    }

    /**
     * @notice Mints a token with server-signed data. Supports delegate.xyz v2 and v1 for cold wallet delegation.
     * @param minter The allowlisted wallet that receives the NFT (cold wallet if delegated)
     * @param imageData The encrypted raw image data of the token (200 bytes)
     * @param traits Encrypted packed bytes8 trait indices
     * @param maxMints Maximum number of mints allowed for this wallet (phase-specific, signed by server)
     * @param deadline Unix timestamp after which the signature is no longer valid
     * @param signature Server signature over (imageData, traits, minter, maxMints, deadline)
     */
    function mint(
        address minter,
        bytes calldata imageData,
        bytes8 traits,
        uint8 maxMints,
        uint256 deadline,
        bytes calldata signature
    ) external payable {
        require(!paused, MintingPaused());
        require(block.timestamp <= deadline, SignatureExpired());
        require(msg.value >= mintPrice, InsufficientPayment());
        require(mintCount[minter] < maxMints, MintLimitReached());

        // Verify caller is minter or a delegate.xyz v2/v1 delegate
        if (msg.sender != minter) {
            require(
                DELEGATE_REGISTRY_V2.checkDelegateForAll(msg.sender, minter, "")
                    || DELEGATE_REGISTRY_V2.checkDelegateForContract(msg.sender, minter, address(normies), "")
                    || DELEGATE_REGISTRY_V1.checkDelegateForAll(msg.sender, minter)
                    || DELEGATE_REGISTRY_V1.checkDelegateForContract(msg.sender, minter, address(normies)),
                NotMinterOrDelegate()
            );
        }

        // Verify server signature over (imageData ++ traits ++ minter ++ maxMints ++ deadline)
        // Uses EIP-191 prefix so backend can sign with standard signMessage
        bytes32 messageHash = keccak256(abi.encodePacked(imageData, traits, minter, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        require(SignatureCheckerLib.isValidSignatureNow(signer, ethSignedHash, signature), InvalidSignature());

        // Track mints
        mintCount[minter]++;

        // Mint the token
        uint256 tokenId = nextTokenId++;
        normies.mint(minter, tokenId);

        // Set the token data
        normiesStorage.setTokenRawImageData(tokenId, imageData);
        normiesStorage.setTokenTraits(tokenId, traits);

        emit Mint(minter, tokenId, imageData, traits);
    }

    /**
     * @notice Mints multiple tokens in a single transaction with a single server-signed message.
     * @param minter The whitelisted wallet that receives the NFTs (cold wallet if delegated)
     * @param imageDataArray Array of encrypted raw image data (200 bytes each)
     * @param traitsArray Array of encrypted packed bytes8 trait indices
     * @param maxMints Maximum number of mints allowed for this wallet (phase-specific, signed by server)
     * @param deadline Unix timestamp after which the signature is no longer valid
     * @param signature Server signature over abi.encode(imageDataArray, traitsArray, minter, maxMints, deadline)
     */
    function batchMint(
        address minter,
        bytes[] calldata imageDataArray,
        bytes8[] calldata traitsArray,
        uint8 maxMints,
        uint256 deadline,
        bytes calldata signature
    ) external payable {
        require(!paused, MintingPaused());
        require(block.timestamp <= deadline, SignatureExpired());
        uint256 count = imageDataArray.length;
        require(count == traitsArray.length, ArrayLengthMismatch());
        require(msg.value >= mintPrice * count, InsufficientPayment());
        require(mintCount[minter] + count <= maxMints, MintLimitReached());

        // Verify caller is minter or a delegate.xyz v2/v1 delegate (once for the batch)
        if (msg.sender != minter) {
            require(
                DELEGATE_REGISTRY_V2.checkDelegateForAll(msg.sender, minter, "")
                    || DELEGATE_REGISTRY_V2.checkDelegateForContract(msg.sender, minter, address(normies), "")
                    || DELEGATE_REGISTRY_V1.checkDelegateForAll(msg.sender, minter)
                    || DELEGATE_REGISTRY_V1.checkDelegateForContract(msg.sender, minter, address(normies)),
                NotMinterOrDelegate()
            );
        }

        // Verify single server signature over all batch data
        bytes32 messageHash = keccak256(abi.encode(imageDataArray, traitsArray, minter, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        require(SignatureCheckerLib.isValidSignatureNow(signer, ethSignedHash, signature), InvalidSignature());

        for (uint256 i; i < count; ++i) {
            mintCount[minter]++;

            uint256 tokenId = nextTokenId++;
            normies.mint(minter, tokenId);

            normiesStorage.setTokenRawImageData(tokenId, imageDataArray[i]);
            normiesStorage.setTokenTraits(tokenId, traitsArray[i]);

            emit Mint(minter, tokenId, imageDataArray[i], traitsArray[i]);
        }
    }

    function withdraw() external onlyOwner {
        (bool success,) = withdrawAddress.call{ value: address(this).balance }("");
        require(success, WithdrawFailed());
    }

    function setWithdrawAddress(address _withdrawAddress) external onlyOwner {
        withdrawAddress = _withdrawAddress;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setMintPrice(uint256 _mintPrice) external onlyOwner {
        mintPrice = _mintPrice;
    }

    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
    }

    function setNormies(address _normies) external onlyOwner {
        normies = INormies(_normies);
    }

    function setNormiesStorage(address _normiesStorage) external onlyOwner {
        normiesStorage = INormiesStorage(_normiesStorage);
    }
}

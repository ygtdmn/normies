// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Test } from "forge-std/src/Test.sol";
import { Normies } from "../src/Normies.sol";
import { NormiesMinter } from "../src/NormiesMinter.sol";
import { NormiesRenderer } from "../src/NormiesRenderer.sol";
import { NormiesStorage } from "../src/NormiesStorage.sol";
import { INormies } from "../src/interfaces/INormies.sol";
import { INormiesRenderer } from "../src/interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "../src/interfaces/INormiesStorage.sol";
import { console2 } from "forge-std/src/console2.sol";
import { Base64 } from "solady/utils/Base64.sol";

contract NormiesTest is Test {
    Normies normies;
    NormiesRenderer renderer;
    NormiesStorage normiesStorage;
    NormiesMinter minter;

    address owner = address(this);
    address unauthorized = address(0xBEEF);

    // Signer keypair for testing
    uint256 constant SIGNER_PK = 0xA11CE;
    address signerAddr;

    uint256 constant MINT_PRICE = 0.005 ether;

    // Example traits: Human, Male, Young, Short Hair, Clean Shaven, No Glasses, Neutral, No Accessories
    bytes8 constant DEFAULT_TRAITS = bytes8(uint64(0x000000000A0D000E));

    // Example traits: Human, Female, Middle-Aged, Curly Hair, Freckles, Classic Shades, Slight Smile, Earring
    bytes8 constant REAL_TRAITS = bytes8(uint64(0x000101020B00010A));

    bytes32 constant TEST_REVEAL_HASH = keccak256("test-secret");

    function setUp() public {
        signerAddr = vm.addr(SIGNER_PK);

        normiesStorage = new NormiesStorage();
        renderer = new NormiesRenderer(INormiesStorage(address(normiesStorage)));
        normies = new Normies(INormiesRenderer(address(renderer)), INormiesStorage(address(normiesStorage)), owner);

        minter = new NormiesMinter(
            INormies(address(normies)), INormiesStorage(address(normiesStorage)), signerAddr, MINT_PRICE, owner
        );

        // Authorize minter on normies and storage
        address[] memory minterAddrs = new address[](1);
        bool[] memory allowed = new bool[](1);
        minterAddrs[0] = address(minter);
        allowed[0] = true;
        normies.setMinterAddresses(minterAddrs, allowed);
        normiesStorage.setAuthorizedWriter(address(minter), true);
    }

    function _createTestBitmap() internal pure returns (bytes memory) {
        // 200-byte bitmap: first row (40 pixels) fully black = first 5 bytes 0xFF
        bytes memory bitmap = new bytes(200);
        for (uint256 i = 0; i < 5; i++) {
            bitmap[i] = bytes1(0xFF);
        }
        return bitmap;
    }

    function _createEmptyBitmap() internal pure returns (bytes memory) {
        // 200-byte bitmap: all pixels off (white)
        return new bytes(200);
    }

    function _createRealBitmap() internal pure returns (bytes memory) {
        // Converted from 1378.svg via script/svg-to-bitmap.mjs
        return hex"00000000000000000000000081800000013500000042d6f0000077fffc000017ffb400003bffd8000057fff60000bfc7ea0001af5af50000fcfebf80005b8db6000177995d0000dff7ba0000dcf13f000077e72b80006fe3270000e7e02b800017e46800001e7e7800001ffff800003ffff400000ffff000000ffff000000ffff000000ffff000000ffff0000007ffe000001ffff000003ffff000008f3ce200000f00c0000007a980800213c388000001e300000001ea000008207e000008103c042004081f0020";
    }

    /// @notice Mirrors the storage contract's XOR decryption for test setup
    function _xorEncryptImageData(bytes memory data, bytes32 _revealHash) internal pure returns (bytes memory) {
        bytes memory encrypted = new bytes(data.length);
        bytes32 key;
        for (uint256 i = 0; i < data.length; i++) {
            if (i & 31 == 0) {
                key = keccak256(abi.encodePacked(_revealHash, i >> 5));
            }
            encrypted[i] = bytes1(uint8(data[i]) ^ uint8(key[i & 31]));
        }
        return encrypted;
    }

    /// @notice Signs a mint message matching the minter contract's expected format
    function _signMint(
        bytes memory imageData,
        bytes8 traits,
        address minterAddr,
        uint8 maxMints,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked(imageData, traits, minterAddr, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Signs a batch mint message matching the minter contract's expected format
    function _signBatchMint(
        bytes[] memory imageDataArray,
        bytes8[] memory traitsArray,
        address minterAddr,
        uint8 maxMints,
        uint256 deadline
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(imageDataArray, traitsArray, minterAddr, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    // ============ Storage Tests ============

    function testSetAndGetImageData() public {
        bytes memory bitmap = _createTestBitmap();
        normiesStorage.setTokenRawImageData(0, bitmap);
        bytes memory retrieved = normiesStorage.getTokenRawImageData(0);
        assertEq(keccak256(retrieved), keccak256(bitmap));
    }

    function testSetAndGetTraits() public {
        normiesStorage.setTokenTraits(0, DEFAULT_TRAITS);
        bytes8 retrieved = normiesStorage.getTokenTraits(0);
        assertEq(retrieved, DEFAULT_TRAITS);
    }

    function testAnyTraitValueAccepted() public {
        bytes8 anyTraits = bytes8(uint64(0xFFFFFFFFFFFFFFFF));
        normiesStorage.setTokenTraits(0, anyTraits);
        assertEq(normiesStorage.getTokenTraits(0), anyTraits);
    }

    function testIsTokenDataSet() public {
        assertFalse(normiesStorage.isTokenDataSet(0));
        normiesStorage.setTokenRawImageData(0, _createTestBitmap());
        assertTrue(normiesStorage.isTokenDataSet(0));
    }

    function testUnauthorizedWrite() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        normiesStorage.setTokenRawImageData(0, _createTestBitmap());
    }

    function testAuthorizedWrite() public {
        normiesStorage.setAuthorizedWriter(unauthorized, true);
        vm.prank(unauthorized);
        normiesStorage.setTokenRawImageData(0, _createTestBitmap());
        assertTrue(normiesStorage.isTokenDataSet(0));
    }

    // ============ Reveal Flow Tests ============

    function testIsNotRevealedByDefault() public view {
        assertFalse(normiesStorage.isRevealed());
    }

    function testSetRevealHash() public {
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
        assertTrue(normiesStorage.isRevealed());
        assertEq(normiesStorage.revealHash(), TEST_REVEAL_HASH);
    }

    function testSetRevealHashOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
    }

    function testSetRevealHashCannotBeZero() public {
        vm.expectRevert();
        normiesStorage.setRevealHash(bytes32(0));
    }

    function testSetRevealHashOnlyOnce() public {
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
        vm.expectRevert();
        normiesStorage.setRevealHash(keccak256("other"));
    }

    // ============ XOR Encryption Round-Trip Tests ============

    function testEncryptDecryptImageData() public {
        bytes memory original = _createTestBitmap();
        bytes memory encrypted = _xorEncryptImageData(original, TEST_REVEAL_HASH);

        normiesStorage.setTokenRawImageData(0, encrypted);

        // Before reveal: getter returns encrypted data
        bytes memory preReveal = normiesStorage.getTokenRawImageData(0);
        assertEq(keccak256(preReveal), keccak256(encrypted));

        // After reveal: getter returns decrypted (original) data
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
        bytes memory postReveal = normiesStorage.getTokenRawImageData(0);
        assertEq(keccak256(postReveal), keccak256(original));
    }

    function testEncryptDecryptTraits() public {
        bytes8 encrypted = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        normiesStorage.setTokenTraits(0, encrypted);

        // Before reveal
        assertEq(normiesStorage.getTokenTraits(0), encrypted);

        // After reveal
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);
        assertEq(normiesStorage.getTokenTraits(0), DEFAULT_TRAITS);
    }

    // ============ Token URI Tests ============

    function testPreRevealTokenURI() public {
        bytes memory encrypted = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        normies.mint(owner, 0);
        normiesStorage.setTokenRawImageData(0, encrypted);
        normiesStorage.setTokenTraits(0, encryptedTraits);

        // Pre-reveal: should return valid URI with silhouette
        string memory uri = normies.tokenURI(0);
        assertTrue(bytes(uri).length > 0);
        console2.log("=== Pre-Reveal Token URI ===");
        console2.log(uri);
    }

    function testTokenURI() public {
        bytes memory encrypted = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        normies.mint(owner, 0);
        normiesStorage.setTokenRawImageData(0, encrypted);
        normiesStorage.setTokenTraits(0, encryptedTraits);
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);

        string memory uri = normies.tokenURI(0);
        assertTrue(bytes(uri).length > 0);
    }

    function testTokenUrINonMintedFails() public {
        vm.expectRevert(Normies.URIQueryForNonExistentToken.selector);
        normies.tokenURI(0);
    }

    function testTokenURIWithoutData() public {
        normies.mint(owner, 0);
        vm.expectRevert();
        normies.tokenURI(0);
    }

    function testRealBitmapTokenURI() public {
        bytes memory encrypted = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        normies.mint(owner, 1378);
        normiesStorage.setTokenRawImageData(1378, encrypted);
        normiesStorage.setTokenTraits(1378, encryptedTraits);
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);

        string memory uri = normies.tokenURI(1378);
        console2.log("=== Token URI for Normie #1378 ===");
        console2.log(uri);
    }

    function testRenderEmptyBitmap() public {
        bytes memory encrypted = _xorEncryptImageData(_createEmptyBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        normies.mint(owner, 0);
        normiesStorage.setTokenRawImageData(0, encrypted);
        normiesStorage.setTokenTraits(0, encryptedTraits);
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);

        // Should succeed — empty bitmap produces SVG with only the background rect
        string memory uri = normies.tokenURI(0);
        assertTrue(bytes(uri).length > 0);
    }

    function testTokenURIContainsLevelTrait() public {
        bytes memory encrypted = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 encryptedTraits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        normies.mint(owner, 0);
        normiesStorage.setTokenRawImageData(0, encrypted);
        normiesStorage.setTokenTraits(0, encryptedTraits);
        normiesStorage.setRevealHash(TEST_REVEAL_HASH);

        string memory uri = normies.tokenURI(0);

        // Decode base64 JSON to check for Level trait
        // The URI starts with "data:application/json;base64,"
        bytes memory uriBytes = bytes(uri);
        // Skip the data URI prefix (29 chars)
        bytes memory base64Part = new bytes(uriBytes.length - 29);
        for (uint256 i = 0; i < base64Part.length; i++) {
            base64Part[i] = uriBytes[i + 29];
        }
        string memory json = string(Base64.decode(string(base64Part)));
        assertTrue(_contains(json, '"display_type":"number","trait_type":"Level","value":1'));
    }

    /// @notice Helper to check if a string contains a substring
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    // ============ Normies Contract Tests ============

    function testTotalSupplyIncreasesOnMint() public {
        assertEq(normies.totalSupply(), 0);
        normies.mint(owner, 0);
        assertEq(normies.totalSupply(), 1);
        normies.mint(owner, 1);
        assertEq(normies.totalSupply(), 2);
    }

    function testTotalSupplyDecreasesOnBurn() public {
        normies.mint(owner, 0);
        normies.mint(owner, 1);
        assertEq(normies.totalSupply(), 2);

        normies.burn(0);
        assertEq(normies.totalSupply(), 1);

        normies.burn(1);
        assertEq(normies.totalSupply(), 0);
    }

    function testMintExceedsMaxSupply() public {
        // Set _totalSupply to 10000 via vm.store (slot 14)
        vm.store(address(normies), bytes32(uint256(14)), bytes32(uint256(10_000)));
        vm.expectRevert(Normies.ExceedsMaxSupply.selector);
        normies.mint(owner, 0);
    }

    function testMintTokenIdExceedsMaxSupply() public {
        vm.expectRevert(Normies.ExceedsMaxSupply.selector);
        normies.mint(owner, 10_000);
    }

    function testBurnByOwner() public {
        normies.mint(owner, 0);
        normies.burn(0);
        assertEq(normies.totalSupply(), 0);
    }

    function testBurnByApproved() public {
        normies.mint(owner, 0);
        normies.approve(unauthorized, 0);

        vm.prank(unauthorized);
        normies.burn(0);
        assertEq(normies.totalSupply(), 0);
    }

    function testBurnByOperator() public {
        normies.mint(owner, 0);
        normies.setApprovalForAll(unauthorized, true);

        vm.prank(unauthorized);
        normies.burn(0);
        assertEq(normies.totalSupply(), 0);
    }

    function testBurnByUnauthorized() public {
        normies.mint(owner, 0);

        vm.prank(unauthorized);
        vm.expectRevert(Normies.NotApprovedOrOwner.selector);
        normies.burn(0);
    }

    function testSetRoyaltyInfo() public {
        address receiver = address(0x7777);
        uint96 feeNumerator = 1000; // 10%
        normies.setRoyaltyInfo(receiver, feeNumerator);

        (address royaltyReceiver, uint256 royaltyAmount) = normies.royaltyInfo(0, 10_000);
        assertEq(royaltyReceiver, receiver);
        assertEq(royaltyAmount, 1000);
    }

    function testSetRoyaltyInfoOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        normies.setRoyaltyInfo(address(0x7777), 1000);
    }

    function testSetRendererContractOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        normies.setRendererContract(INormiesRenderer(address(0x1)));
    }

    function testSetStorageContractOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        normies.setStorageContract(INormiesStorage(address(0x1)));
    }

    function testSetMinterAddressesOnlyOwner() public {
        address[] memory addrs = new address[](1);
        bool[] memory allowed = new bool[](1);
        addrs[0] = unauthorized;
        allowed[0] = true;

        vm.prank(unauthorized);
        vm.expectRevert();
        normies.setMinterAddresses(addrs, allowed);
    }

    function testSignalMetadataUpdateOnlyMinters() public {
        vm.prank(unauthorized);
        vm.expectRevert(Normies.NotMinter.selector);
        normies.signalMetadataUpdate();
    }

    function testSignalMetadataUpdateByMinter() public {
        address minterAddr = address(0xAAAA);
        address[] memory addrs = new address[](1);
        bool[] memory allowed = new bool[](1);
        addrs[0] = minterAddr;
        allowed[0] = true;
        normies.setMinterAddresses(addrs, allowed);

        vm.prank(minterAddr);
        normies.signalMetadataUpdate();
    }

    function testMintOnlyMinters() public {
        vm.prank(unauthorized);
        vm.expectRevert(Normies.NotMinter.selector);
        normies.mint(unauthorized, 0);
    }

    // ============ Minter Tests ============

    function testMintWithCorrectPrice() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint8 maxMints = 2;

        bytes memory sig = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, block.timestamp + 900, sig);

        assertEq(normies.totalSupply(), 1);
        assertEq(normies.ownerOf(0), user);
        assertEq(minter.mintCount(user), 1);
        assertTrue(normiesStorage.isTokenDataSet(0));
    }

    function testMintInsufficientPayment() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint8 maxMints = 2;

        bytes memory sig = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InsufficientPayment.selector);
        minter.mint{ value: MINT_PRICE - 1 }(user, imageData, traits, maxMints, block.timestamp + 900, sig);
    }

    function testMintLimitReached() public {
        address user = address(0x1234);
        uint8 maxMints = 1;
        vm.deal(user, 1 ether);

        // First mint succeeds
        bytes memory imageData1 = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits1 = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig1 = _signMint(imageData1, traits1, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData1, traits1, maxMints, block.timestamp + 900, sig1);
        assertEq(minter.mintCount(user), 1);

        // Second mint fails (maxMints = 1)
        bytes memory imageData2 = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 traits2 = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig2 = _signMint(imageData2, traits2, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintLimitReached.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData2, traits2, maxMints, block.timestamp + 900, sig2);
    }

    function testMintCountTracking() public {
        address user = address(0x1234);
        uint8 maxMints = 10;
        vm.deal(user, 1 ether);

        assertEq(minter.mintCount(user), 0);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, block.timestamp + 900, sig);
        assertEq(minter.mintCount(user), 1);

        // Mint a second with different data
        bytes memory imageData2 = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        bytes8 traits2 = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig2 = _signMint(imageData2, traits2, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData2, traits2, maxMints, block.timestamp + 900, sig2);
        assertEq(minter.mintCount(user), 2);
        assertEq(normies.totalSupply(), 2);
    }

    function testMintInvalidSignature() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint8 maxMints = 2;
        uint256 deadline = block.timestamp + 900;

        // Sign with wrong private key
        bytes32 messageHash = keccak256(abi.encodePacked(imageData, traits, user, maxMints, deadline));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, ethSignedHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, deadline, badSig);
    }

    function testMintWithDelegation() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        uint8 maxMints = 2;

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, maxMints, block.timestamp + 900);

        // Mock delegate.xyz registry: hotWallet is delegate for coldWallet
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY()),
            abi.encodeCall(minter.DELEGATE_REGISTRY().checkDelegateForAll, (hotWallet, coldWallet, "")),
            abi.encode(true)
        );

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, maxMints, block.timestamp + 900, sig);

        // NFT should be owned by cold wallet
        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(minter.mintCount(coldWallet), 1);
    }

    function testMintDelegationNotAuthorized() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        uint8 maxMints = 2;

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, coldWallet, maxMints, block.timestamp + 900);

        // Mock delegate.xyz registry: NOT delegated
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY()),
            abi.encodeCall(minter.DELEGATE_REGISTRY().checkDelegateForAll, (hotWallet, coldWallet, "")),
            abi.encode(false)
        );
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY()),
            abi.encodeCall(
                minter.DELEGATE_REGISTRY().checkDelegateForContract, (hotWallet, coldWallet, address(normies), "")
            ),
            abi.encode(false)
        );

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        vm.expectRevert(NormiesMinter.NotMinterOrDelegate.selector);
        minter.mint{ value: MINT_PRICE }(coldWallet, imageData, traits, maxMints, block.timestamp + 900, sig);
    }

    function testWithdraw() public {
        // Fund the minter contract via a mint
        address user = address(0x1234);
        uint8 maxMints = 2;
        vm.deal(user, 1 ether);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, block.timestamp + 900, sig);

        // Set withdraw address to an EOA (test contract has no receive())
        address payable withdrawEOA = payable(address(0x9999));
        minter.setWithdrawAddress(withdrawEOA);

        uint256 balanceBefore = withdrawEOA.balance;
        minter.withdraw();
        assertEq(withdrawEOA.balance, balanceBefore + MINT_PRICE);
        assertEq(address(minter).balance, 0);
    }

    function testWithdrawOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        minter.withdraw();
    }

    function testSetMintPrice() public {
        uint256 newPrice = 0.01 ether;
        minter.setMintPrice(newPrice);
        assertEq(minter.mintPrice(), newPrice);
    }

    // ============ Batch Mint Tests ============

    function testBatchMintBasic() public {
        address user = address(0x1234);
        uint8 maxMints = 10;
        uint256 count = 3;
        vm.deal(user, 1 ether);

        bytes[] memory imageDataArray = new bytes[](count);
        bytes8[] memory traitsArray = new bytes8[](count);

        imageDataArray[0] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        traitsArray[0] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        imageDataArray[1] = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        traitsArray[1] = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        imageDataArray[2] = _xorEncryptImageData(_createEmptyBitmap(), TEST_REVEAL_HASH);
        traitsArray[2] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        bytes memory sig =
            _signBatchMint(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE * count }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, sig
        );

        assertEq(normies.totalSupply(), 3);
        assertEq(normies.ownerOf(0), user);
        assertEq(normies.ownerOf(1), user);
        assertEq(normies.ownerOf(2), user);
        assertEq(minter.mintCount(user), 3);
        assertTrue(normiesStorage.isTokenDataSet(0));
        assertTrue(normiesStorage.isTokenDataSet(1));
        assertTrue(normiesStorage.isTokenDataSet(2));
    }

    function testBatchMintInsufficientPayment() public {
        address user = address(0x1234);
        uint8 maxMints = 10;
        uint256 count = 3;
        vm.deal(user, 1 ether);

        bytes[] memory imageDataArray = new bytes[](count);
        bytes8[] memory traitsArray = new bytes8[](count);

        for (uint256 i = 0; i < count; i++) {
            imageDataArray[i] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            traitsArray[i] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        }

        bytes memory sig =
            _signBatchMint(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        vm.expectRevert(NormiesMinter.InsufficientPayment.selector);
        // Pay for 2 but try to mint 3
        minter.batchMint{ value: MINT_PRICE * 2 }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, sig
        );
    }

    function testBatchMintLimitExceeded() public {
        address user = address(0x1234);
        uint8 maxMints = 2;
        uint256 count = 3;
        vm.deal(user, 1 ether);

        bytes[] memory imageDataArray = new bytes[](count);
        bytes8[] memory traitsArray = new bytes8[](count);

        for (uint256 i = 0; i < count; i++) {
            imageDataArray[i] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            traitsArray[i] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        }

        bytes memory sig =
            _signBatchMint(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintLimitReached.selector);
        minter.batchMint{ value: MINT_PRICE * count }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, sig
        );
    }

    function testBatchMintArrayLengthMismatch() public {
        address user = address(0x1234);
        uint8 maxMints = 10;
        vm.deal(user, 1 ether);

        bytes[] memory imageDataArray = new bytes[](2);
        bytes8[] memory traitsArray = new bytes8[](3);

        vm.prank(user);
        vm.expectRevert(NormiesMinter.ArrayLengthMismatch.selector);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, hex""
        );
    }

    function testBatchMintInvalidSignature() public {
        address user = address(0x1234);
        uint8 maxMints = 10;
        uint256 count = 2;
        vm.deal(user, 1 ether);

        bytes[] memory imageDataArray = new bytes[](count);
        bytes8[] memory traitsArray = new bytes8[](count);

        imageDataArray[0] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        traitsArray[0] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        imageDataArray[1] = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        traitsArray[1] = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        // Sign with wrong private key
        bytes32 messageHash =
            keccak256(abi.encode(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, ethSignedHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert(NormiesMinter.InvalidSignature.selector);
        minter.batchMint{ value: MINT_PRICE * count }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, badSig
        );
    }

    function testBatchMintWithDelegation() public {
        address coldWallet = address(0xC01D);
        address hotWallet = address(0xABCD);
        uint8 maxMints = 10;
        uint256 count = 2;

        bytes[] memory imageDataArray = new bytes[](count);
        bytes8[] memory traitsArray = new bytes8[](count);

        imageDataArray[0] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        traitsArray[0] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        imageDataArray[1] = _xorEncryptImageData(_createRealBitmap(), TEST_REVEAL_HASH);
        traitsArray[1] = REAL_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        bytes memory sig =
            _signBatchMint(imageDataArray, traitsArray, coldWallet, maxMints, block.timestamp + 900);

        // Mock delegate.xyz registry
        vm.mockCall(
            address(minter.DELEGATE_REGISTRY()),
            abi.encodeCall(minter.DELEGATE_REGISTRY().checkDelegateForAll, (hotWallet, coldWallet, "")),
            abi.encode(true)
        );

        vm.deal(hotWallet, 1 ether);
        vm.prank(hotWallet);
        minter.batchMint{ value: MINT_PRICE * count }(
            coldWallet, imageDataArray, traitsArray, maxMints, block.timestamp + 900, sig
        );

        assertEq(normies.ownerOf(0), coldWallet);
        assertEq(normies.ownerOf(1), coldWallet);
        assertEq(minter.mintCount(coldWallet), 2);
    }

    function testBatchMintSingleItem() public {
        address user = address(0x1234);
        uint8 maxMints = 10;
        vm.deal(user, 1 ether);

        bytes[] memory imageDataArray = new bytes[](1);
        bytes8[] memory traitsArray = new bytes8[](1);

        imageDataArray[0] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        traitsArray[0] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);

        bytes memory sig =
            _signBatchMint(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, sig
        );

        assertEq(normies.totalSupply(), 1);
        assertEq(normies.ownerOf(0), user);
        assertEq(minter.mintCount(user), 1);
    }

    function testFreeMintWhenPriceZero() public {
        minter.setMintPrice(0);

        address user = address(0x1234);
        uint8 maxMints = 2;

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        minter.mint{ value: 0 }(user, imageData, traits, maxMints, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), user);
    }

    // ============ Deadline Tests ============

    function testMintExpiredDeadline() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint8 maxMints = 2;
        uint256 deadline = block.timestamp - 1; // expired

        bytes memory sig = _signMint(imageData, traits, user, maxMints, deadline);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.SignatureExpired.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, deadline, sig);
    }

    function testBatchMintExpiredDeadline() public {
        address user = address(0x1234);
        uint8 maxMints = 10;
        uint256 count = 2;
        uint256 deadline = block.timestamp - 1; // expired
        vm.deal(user, 1 ether);

        bytes[] memory imageDataArray = new bytes[](count);
        bytes8[] memory traitsArray = new bytes8[](count);

        for (uint256 i = 0; i < count; i++) {
            imageDataArray[i] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            traitsArray[i] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        }

        bytes memory sig = _signBatchMint(imageDataArray, traitsArray, user, maxMints, deadline);

        vm.prank(user);
        vm.expectRevert(NormiesMinter.SignatureExpired.selector);
        minter.batchMint{ value: MINT_PRICE * count }(user, imageDataArray, traitsArray, maxMints, deadline, sig);
    }

    function testMintDeadlineExactBoundary() public {
        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint8 maxMints = 2;
        uint256 deadline = block.timestamp; // exact boundary — should succeed

        bytes memory sig = _signMint(imageData, traits, user, maxMints, deadline);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, deadline, sig);

        assertEq(normies.totalSupply(), 1);
        assertEq(normies.ownerOf(0), user);
    }

    // ============ Pause Tests ============

    function testMintWhilePaused() public {
        minter.setPaused(true);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint8 maxMints = 2;

        bytes memory sig = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintingPaused.selector);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, block.timestamp + 900, sig);
    }

    function testBatchMintWhilePaused() public {
        minter.setPaused(true);

        address user = address(0x1234);
        uint8 maxMints = 10;
        uint256 count = 2;
        vm.deal(user, 1 ether);

        bytes[] memory imageDataArray = new bytes[](count);
        bytes8[] memory traitsArray = new bytes8[](count);

        for (uint256 i = 0; i < count; i++) {
            imageDataArray[i] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            traitsArray[i] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        }

        bytes memory sig =
            _signBatchMint(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        vm.expectRevert(NormiesMinter.MintingPaused.selector);
        minter.batchMint{ value: MINT_PRICE * count }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, sig
        );
    }

    function testUnpauseAndMint() public {
        minter.setPaused(true);
        minter.setPaused(false);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        address user = address(0x1234);
        uint8 maxMints = 2;

        bytes memory sig = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);

        vm.deal(user, 1 ether);
        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, block.timestamp + 900, sig);

        assertEq(normies.ownerOf(0), user);
    }

    function testSetPausedOnlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        minter.setPaused(true);
    }

    // ============ NextTokenId Tests ============

    function testNextTokenIdIncrementsCorrectly() public {
        address user = address(0x1234);
        uint8 maxMints = 10;
        vm.deal(user, 1 ether);

        assertEq(minter.nextTokenId(), 0);

        bytes memory imageData = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
        bytes8 traits = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        bytes memory sig = _signMint(imageData, traits, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        minter.mint{ value: MINT_PRICE }(user, imageData, traits, maxMints, block.timestamp + 900, sig);

        assertEq(minter.nextTokenId(), 1);
        assertEq(normies.ownerOf(0), user);

        // Batch mint 2 more
        bytes[] memory imageDataArray = new bytes[](2);
        bytes8[] memory traitsArray = new bytes8[](2);

        for (uint256 i = 0; i < 2; i++) {
            imageDataArray[i] = _xorEncryptImageData(_createTestBitmap(), TEST_REVEAL_HASH);
            traitsArray[i] = DEFAULT_TRAITS ^ bytes8(TEST_REVEAL_HASH);
        }

        bytes memory batchSig =
            _signBatchMint(imageDataArray, traitsArray, user, maxMints, block.timestamp + 900);

        vm.prank(user);
        minter.batchMint{ value: MINT_PRICE * 2 }(
            user, imageDataArray, traitsArray, maxMints, block.timestamp + 900, batchSig
        );

        assertEq(minter.nextTokenId(), 3);
        assertEq(normies.ownerOf(1), user);
        assertEq(normies.ownerOf(2), user);
    }
}

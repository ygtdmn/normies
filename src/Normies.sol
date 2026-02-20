// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { OwnableBasic } from "@limitbreak/creator-token-standards/src/access/OwnableBasic.sol";
import { ERC721C } from "@limitbreak/creator-token-standards/src/erc721c/ERC721C.sol";
import { ERC721OpenZeppelin } from "@limitbreak/creator-token-standards/src/token/erc721/ERC721OpenZeppelin.sol";
import {
    BasicRoyalties,
    ERC2981
} from "@limitbreak/creator-token-standards/src/programmable-royalties/BasicRoyalties.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";
import { INormiesRenderer } from "./interfaces/INormiesRenderer.sol";
import { INormiesStorage } from "./interfaces/INormiesStorage.sol";

// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@**************@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%####+=+++==+++=++*####%@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%%#======*%#==%%+=*%#====#%%@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*-=--@@+-=-=----#@*-=----=-*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@+=+=+%%====*%%%%%%+=*%#==%%+=+=+@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@+=+=+++##+=++*+++++=++*##+++=+=+@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@+=+=+****+=+**====**+=+****+=+=+@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@%%+=+=+%%==+=*@%====%@*=+==%%+=+=+%%@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@--=-=-=--@@@@@@@@@@@@@@@#----=-=-=--@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@--=-=-+@@@@@@@@@@@@@@@@@@@@@@@@*-=--@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@==+=*##++++++++++++++++++++++%@*=+==@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@==+=+**==**+=+=+====+=+=+====#@*=+==@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@==+=+=+++##+=+=+++==+=+++==++##*=+==@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@--=-+-+%%--=-+-+%%--=-*%#--%%+-=-=--@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@--=-*@#----#@*-=--@@+-=-=----=-=-=--@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@====+=+%%==+=*%#====#%*=+%%==#%*====@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@==+=+=+++##+=+++====+++=+@@==+++=+==@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@%*#**==+=+=+++**+=+=++++++=+=+**+++=+=+++**#*%@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@*=+====+=+=+%%====+=+@@@@+=+====%%+=+=+%%==+=*@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@*-+@@--#@*-=----=-*@@@@@@@@*-=----=-*@#--@@+-*@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@%%@@--#@@%%%%%%%%*-+@@@@+-*%%%%%%%%@@#--@@%%@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@%++==++#@@@@@@@@%#%@@@@%#%@@@@@@@@#++==++%@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@%**==+=+*#@@******************@@#*+=+==**%@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@+++=+=+##==+=+=+====+=+=+==##+=+=+++@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@%%+-=-=----=-=-=----=-=-=----=-=-+%%@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@--=-=-=----=-=-=----=-=-=----=-=-=--@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@====+========*%%%%%%%%*========+====@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@**+=+=+====+=++*++++*++=+====+=+=+**@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@+=+=+====+=+=+====+=+=+====+=+=+@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@+=+========+========+========+=+@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@+-=-=----=-=-=----=-=-=----=-=-+@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@%%*-=----=-+-=----=-+-=----=-*%%@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*=+====+=+=+====+=+=+====+=*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*=+====+=+=+====+=+=+====+=*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*=+====+=+=+====+=+=+====+=*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*-=----=-=-=----=-=-=----=-*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@@@+-*@@@@--=-=-=----=-=-=--@@@@*-+@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@@@@@@==+=*@@@@%%+=+=+====+=+=+%%@@@@*=+==@@@@@@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@@@@@@@@#****==+=+**@@@@+=+=+====+=+=+@@@@**+=+==****#@@@@@@@@@@@@@@@@@@@@@@
// @@@@@@@@@@@@@@@%######*=+====+=+=+####*++=+++==+++=+####+=+=+====+=*######%@@@@@@@@@@@@@@@
// @@@@@@@@@@@%%%%#======+========+======#%*=+%%==#%*========+========+======#%%%%@@@@@@@@@@@
// @@@@@@@@@@@+-=-=----=-=-=----=-=-=----=-=-=----=-=-=----=-=-=----=-=-=----=-=-+@@@@@@@@@@@
// @@@@*=+======+========+========+========+========+========+========+========+======+=*@@@@
// @@*++=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=++*@@
// @@+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+@@
// ##+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+====+=+=+##
// --=-=-=----=-=-=----=-=-=----=-=-=----=-=-=----=-=-=----=-=-=----=-=-=----=-=-=----=-=-=--

/**
 * @title Normies
 * @notice On-Chain Generative Faces
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 */
contract Normies is ERC721C, BasicRoyalties, OwnableBasic, Lifebuoy {
    INormiesRenderer public rendererContract;
    INormiesStorage public storageContract;
    uint256 private _totalSupply;

    mapping(address => bool) public minterAddresses;

    error NotApprovedOrOwner();
    error NotMinter();
    error ExceedsMaxSupply();
    error URIQueryForNonExistentToken();

    event MinterAddressSet(address indexed minter, bool allowed);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    constructor(
        INormiesRenderer _renderer,
        INormiesStorage _storage,
        address royaltyReceiver
    ) ERC721OpenZeppelin("Normies", "NORMIES") OwnableBasic() BasicRoyalties(royaltyReceiver, 500) Lifebuoy() {
        rendererContract = _renderer;
        storageContract = _storage;
    }

    modifier onlyMinters() {
        require(msg.sender == owner() || minterAddresses[msg.sender], NotMinter());
        _;
    }

    function maxSupply() public pure returns (uint256) {
        return 10_000;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), URIQueryForNonExistentToken());
        return rendererContract.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721C, ERC2981) returns (bool) {
        return ERC721C.supportsInterface(interfaceId) || super.supportsInterface(interfaceId);
    }

    function mint(address to, uint256 tokenId) external onlyMinters {
        require(_totalSupply < maxSupply(), ExceedsMaxSupply());
        require(tokenId < maxSupply(), ExceedsMaxSupply());
        _mint(to, tokenId);
        _totalSupply++;
    }

    function burn(uint256 tokenId) external {
        require(_isApprovedOrOwner(msg.sender, tokenId), NotApprovedOrOwner());
        _burn(tokenId);
        _totalSupply--;
    }

    function setRoyaltyInfo(address receiver, uint96 feeNumerator) external onlyOwner {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function setRendererContract(INormiesRenderer _renderer) external onlyOwner {
        rendererContract = _renderer;
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    function setStorageContract(INormiesStorage _storage) external onlyOwner {
        storageContract = _storage;
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    function setMinterAddresses(address[] calldata addresses, bool[] calldata allowed) external onlyOwner {
        for (uint256 i = 0; i < addresses.length; i++) {
            minterAddresses[addresses[i]] = allowed[i];
            emit MinterAddressSet(addresses[i], allowed[i]);
        }
    }

    function signalMetadataUpdate() external onlyMinters {
        emit BatchMetadataUpdate(0, type(uint256).max);
    }
}

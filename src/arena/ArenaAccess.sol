// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { NormiesAccess } from "../NormiesAccess.sol";
import { NormiesArenaStorage, IArenaPixels, IArenaAdapter } from "../NormiesArenaStorage.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title ArenaAccess
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Base for the Arena logic contracts (NormiesArena, NormiesArenaQueue, NormiesArenaSkins): the storage they
 *         write to, the pixel ledger, a pause switch, and agent linking.
 *
 *         Each logic contract is tied to one NormiesArenaStorage for its lifetime and writes to it only while the
 *         storage owner lists it as an authorized writer. Every logic contract starts paused; the owner or
 *         GUARDIAN_ROLE pauses and unpauses it.
 *
 *         Holds no tokens. ETH or tokens sent to it by mistake can be recovered with solady's Lifebuoy: by the
 *         owner, and by the deployer until it locks its own access with lockRescue(1).
 */
abstract contract ArenaAccess is NormiesAccess, ReentrancyGuard, Lifebuoy {
    /// @notice A malformed argument (a zero address or amount, an out-of-range id or value, an empty or oversized
    ///         batch), or an agent binding that does not point at the Normie.
    error InvalidInput();
    /// @notice The contract is paused.
    error Paused();
    /// @notice The call is not allowed in the current state.
    error InvalidState();

    /// @notice The Arena storage this contract reads and writes.
    NormiesArenaStorage public immutable store;
    /// @notice The pixel ledger, read from the storage at deployment.
    IArenaPixels public immutable pixels;
    /// @notice Whether functions guarded by whenRunning revert. All other functions work while paused. Starts paused.
    bool public paused = true;

    /// @notice The pause switch was set to `paused`.
    event PauseChanged(bool paused);

    /// @param store_ The NormiesArenaStorage to use.
    /// @param admin  The owner.
    constructor(address store_, address admin) {
        require(store_ != address(0) && admin != address(0), InvalidInput());
        store = NormiesArenaStorage(store_);
        pixels = NormiesArenaStorage(store_).pixels();
        _initializeOwner(admin);
    }

    /// @dev Reverts with Paused while the contract is paused.
    modifier whenRunning() {
        require(!paused, Paused());
        _;
    }

    /// @notice Pause or unpause the functions guarded by whenRunning. Owner or GUARDIAN_ROLE. Each Arena logic
    ///         contract has its own switch and its own roles. Withdrawals are on the storage and have no pause.
    function setPaused(bool value) external onlyOwnerOrRoles(GUARDIAN_ROLE) {
        paused = value;
        emit PauseChanged(value);
    }

    /// @notice Link Normie `id` to agent `agentId`, replacing any earlier link. The Normie's holder or one of its
    ///         delegates only (see NormiesArenaStorage.holderFor, which reverts with Forbidden for anyone else and
    ///         Burned for a burned Normie). The adapter's binding for `agentId` must be the ERC-721 binding to this
    ///         Normie, or it reverts with InvalidInput.
    function bindAgent(uint256 id, uint256 agentId) external {
        store.holderFor(id, msg.sender);
        _bindAgent(id, agentId);
    }

    /// @dev Links the Normie to the agent after checking the adapter binding. The caller check is the caller's.
    function _bindAgent(uint256 id, uint256 agentId) internal {
        require(_bindingMatches(id, agentId), InvalidInput());
        store.linkAgent(id, agentId);
    }

    /// @dev Whether the Normie is linked to an agent whose adapter binding still points at it.
    function _awake(uint256 id) internal view returns (bool) {
        return store.agentBound(id) && _bindingMatches(id, store.agentOf(id));
    }

    /// @dev Whether the adapter's binding for `agentId` is the ERC-721 binding (standard 0) to Normie `id`.
    function _bindingMatches(uint256 id, uint256 agentId) private view returns (bool) {
        (uint8 standard, address boundAddress, uint256 tokenId) = store.adapter().bindingOf(agentId);
        return id < store.ID_BOUND() && standard == 0 && boundAddress == address(store.collection()) && tokenId == id;
    }
}

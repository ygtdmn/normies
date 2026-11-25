// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { NormiesAccess } from "./NormiesAccess.sol";
import { NormiesArenaStorage } from "./NormiesArenaStorage.sol";
import { INormiesCanvasStorageV2 } from "./interfaces/INormiesCanvasStorageV2.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesPixelGifts
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice Lets a wallet the owner picked give away pixels from its own wallet balance, with no listing on the Pixel
 *         Market: no price, no fee. Three places a gift can land:
 *
 *           a wallet           giftToWallet   the receiver's wallet balance, cooling down like bought pixels
 *           a Normie's canvas  giftToNormie   the pixels attached to the Normie, as if its holder had deposited them
 *           a Normie's Arena   giftToArena    the Normie's Arena balance
 *
 *         Only GIFTER_ROLE can give, and only the caller's own pixels: no function takes a `from`, and no allowance
 *         is ever used. Everyone else keeps moving pixels between wallets through the market.
 *
 *         A gift to a Normie belongs to the Normie, whoever holds it: the holder withdraws it from the canvas or
 *         from the Arena as usual, and the giver cannot take it back. Burned Normies are refused. An Arena gift
 *         never registers a Normie (one that has not joined keeps the pixels and brings them along when its holder
 *         joins) and does not check the agent link; a registered Normie that sat out for lack of funds plays again
 *         from the next round its balance covers.
 *
 *         A wallet gift is refused for a receiver that holds a mover role on the ledger (the market, the canvas,
 *         the Arena): pixels sent there would belong to no one.
 *
 *         Needs ROLE_CANVAS on the pixel ledger (attaching pixels to a Normie is a canvas-role call) and to be an
 *         authorized writer of the Arena storage. Holds no pixels. ETH or tokens sent to it by mistake can be
 *         recovered with solady's Lifebuoy: by the owner, and by the deployer until it locks its own access with
 *         lockRescue(1).
 */
contract NormiesPixelGifts is NormiesAccess, ReentrancyGuard, Lifebuoy {
    /// @notice A zero address or amount, a receiver that is the caller or a ledger mover, a Normie id out of range,
    ///         or an empty, oversized or mismatched batch.
    error InvalidInput();
    /// @notice The contract is paused.
    error Paused();
    /// @notice The Normie is burned.
    error Burned();

    /// @notice `from` gave `amount` pixels to the wallet `to`.
    event GiftedToWallet(address indexed from, address indexed to, uint256 amount);
    /// @notice `from` gave `amount` pixels to Normie `id`'s canvas balance.
    event GiftedToNormie(address indexed from, uint256 indexed id, uint256 amount);
    /// @notice `from` gave `amount` pixels to Normie `id`'s Arena balance.
    event GiftedToArena(address indexed from, uint256 indexed id, uint256 amount);
    /// @notice The pause switch was set to `paused`.
    event PauseChanged(bool paused);

    /// @notice Role that may give away its own pixels (_ROLE_5, value 32). Granted by the owner with grantRoles.
    uint256 public constant GIFTER_ROLE = _ROLE_5;
    /// @notice Most entries in one batch call.
    uint256 public constant MAX_BATCH = 100;

    /// @notice The Arena storage credited by giftToArena. Normie ids and burns are read from it too.
    NormiesArenaStorage public immutable store;
    /// @notice The pixel ledger (NormiesCanvasStorageV2), read from the Arena storage at deployment.
    INormiesCanvasStorageV2 public immutable pixels;
    /// @notice Whether giving is stopped. Starts running: nothing can be given until the owner grants GIFTER_ROLE.
    bool public paused;

    /// @param store_ The NormiesArenaStorage to credit.
    /// @param admin  The owner.
    constructor(address store_, address admin) {
        require(store_ != address(0) && admin != address(0), InvalidInput());
        store = NormiesArenaStorage(store_);
        pixels = INormiesCanvasStorageV2(address(NormiesArenaStorage(store_).pixels()));
        _initializeOwner(admin);
    }

    /// @dev Reverts with Paused while the contract is paused.
    modifier whenRunning() {
        require(!paused, Paused());
        _;
    }

    /// @dev Reverts with InvalidInput unless both lists have the same 1 to MAX_BATCH entries.
    modifier batch(uint256 n, uint256 m) {
        require(n == m && n > 0 && n <= MAX_BATCH, InvalidInput());
        _;
    }

    /// @notice Stop or resume every gift. Owner or GUARDIAN_ROLE.
    function setPaused(bool value) external onlyOwnerOrRoles(GUARDIAN_ROLE) {
        paused = value;
        emit PauseChanged(value);
    }

    // ──────────────────────────────────────────────
    //  To a wallet
    // ──────────────────────────────────────────────

    /// @notice Give `amount` of the caller's wallet pixels to the wallet `to`. GIFTER_ROLE only, while running.
    ///         Reverts on the ledger when the caller's spendable balance does not cover it.
    function giftToWallet(address to, uint256 amount) external onlyRoles(GIFTER_ROLE) whenRunning nonReentrant {
        _giftToWallet(to, amount);
    }

    /// @notice giftToWallet for several wallets, up to MAX_BATCH. A single failure reverts the batch.
    function giftToWalletBatch(
        address[] calldata tos,
        uint256[] calldata amounts
    ) external onlyRoles(GIFTER_ROLE) whenRunning nonReentrant batch(tos.length, amounts.length) {
        for (uint256 i; i < tos.length; ++i) {
            _giftToWallet(tos[i], amounts[i]);
        }
    }

    // ──────────────────────────────────────────────
    //  To a Normie's canvas
    // ──────────────────────────────────────────────

    /// @notice Attach `amount` of the caller's wallet pixels to Normie `id`, whoever holds it. GIFTER_ROLE only,
    ///         while running. The same as a holder's deposit on the canvas: the Normie's pixel budget grows, and
    ///         its holder can paint with it or withdraw it. Reverts with Burned for a burned Normie.
    function giftToNormie(uint256 id, uint256 amount) external onlyRoles(GIFTER_ROLE) whenRunning nonReentrant {
        _giftToNormie(id, amount);
    }

    /// @notice giftToNormie for several Normies, up to MAX_BATCH. A single failure reverts the batch.
    function giftToNormieBatch(
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external onlyRoles(GIFTER_ROLE) whenRunning nonReentrant batch(ids.length, amounts.length) {
        for (uint256 i; i < ids.length; ++i) {
            _giftToNormie(ids[i], amounts[i]);
        }
    }

    // ──────────────────────────────────────────────
    //  To a Normie's Arena balance
    // ──────────────────────────────────────────────

    /// @notice Add `amount` of the caller's wallet pixels to Normie `id`'s Arena balance, whoever holds it.
    ///         GIFTER_ROLE only, while running. Never registers the Normie. Reverts with Burned for a burned Normie.
    function giftToArena(uint256 id, uint256 amount) external onlyRoles(GIFTER_ROLE) whenRunning nonReentrant {
        _giftToArena(id, amount);
    }

    /// @notice giftToArena for several Normies, up to MAX_BATCH. A single failure reverts the batch.
    function giftToArenaBatch(
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external onlyRoles(GIFTER_ROLE) whenRunning nonReentrant batch(ids.length, amounts.length) {
        for (uint256 i; i < ids.length; ++i) {
            _giftToArena(ids[i], amounts[i]);
        }
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    /// @dev Moves the caller's pixels to a wallet that is neither the caller nor a ledger mover.
    function _giftToWallet(address to, uint256 amount) private {
        require(to != address(0) && to != msg.sender && amount > 0, InvalidInput());
        require(pixels.moverRoles(to) == 0, InvalidInput());
        pixels.moveBalance(msg.sender, to, amount);
        emit GiftedToWallet(msg.sender, to, amount);
    }

    /// @dev Attaches the caller's pixels to a Normie that exists.
    function _giftToNormie(uint256 id, uint256 amount) private {
        _requireLive(id, amount);
        pixels.attach(msg.sender, id, amount, INormiesCanvasStorageV2.Reason.Deposit);
        emit GiftedToNormie(msg.sender, id, amount);
    }

    /// @dev Moves the caller's pixels into the Arena storage and credits them to the Normie, without registering it.
    function _giftToArena(uint256 id, uint256 amount) private {
        _requireLive(id, amount);
        pixels.moveBalance(msg.sender, address(store), amount);
        store.deposit(id, msg.sender, amount, false);
        emit GiftedToArena(msg.sender, id, amount);
    }

    /// @dev A non-zero amount for a Normie id in range that is not burned.
    function _requireLive(uint256 id, uint256 amount) private view {
        require(amount > 0 && id < store.ID_BOUND(), InvalidInput());
        require(!store.isBurned(id), Burned());
    }
}

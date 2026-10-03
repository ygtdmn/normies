// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { INormiesCanvasStorage } from "./interfaces/INormiesCanvasStorage.sol";
import { INormiesCanvasStorageV2 } from "./interfaces/INormiesCanvasStorageV2.sol";
import { INormiesCanvasV1 } from "./interfaces/INormiesCanvasV1.sol";
import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { NormiesAccess } from "./NormiesAccess.sol";
import { Lifebuoy } from "solady/utils/Lifebuoy.sol";

/**
 * @title NormiesCanvasStorageV2
 * @author Normies by Serc (https://x.com/serc1n)
 * @author Smart Contract by Yigit Duman (https://x.com/yigitduman)
 * @notice The canvas data, kept apart from the canvas logic so the logic can be replaced without moving anything.
 *
 *         Overlays: plaintext bitmaps of any grid size, one SSTORE2 pointer per token. Every write and clear emits
 *         an event. Tokens never written here fall back to the original NormiesCanvasStorage; a cleared token no
 *         longer falls back. Authorized writers may write overlays.
 *
 *         Token state: each token's grid size, blank-base flag and canvas delegate live here too, written only by
 *         the canvas role, so a later canvas can replace the logic without copying anything. Delegations made on
 *         the original canvas are snapshotted by the migration script, then copied and sealed atomically.
 *
 *         Pixels: the single source of truth for pixel supply. A pixel either sits in a wallet balance or is
 *         attached to a Normie, and every pixel is the same as every other. Only movers with a role may move them:
 *         the canvas creates, attaches and detaches pixels; the market and a future wrapper can only move wallet
 *         balances. Pixels are only ever spent by their holder, or by a wallet the holder approved for an amount
 *         (approve / allowance, like an ERC20; an allowance is custody of that amount, whether it is spent from the
 *         wallet or from a Normie the holder owns); delegations of any kind never reach them. The owner can pause
 *         every third-party allowance use at once (setAllowancesPaused) while holders keep acting for themselves and
 *         can still revoke. Balances earned on the original NormiesCanvas are copied in once, at cutover, by
 *         migrateBatch (which reads them from that canvas itself), and the copy is closed with finalizeMigration.
 */
contract NormiesCanvasStorageV2 is INormiesCanvasStorageV2, NormiesAccess, Lifebuoy {
    error NotAuthorized();
    error ZeroAddress();
    error TokenNotTransformed(uint256 tokenId);
    error InsufficientBalance(address account, uint256 balance, uint256 needed);
    error InsufficientAllowance(address owner, address spender, uint256 allowed, uint256 needed);
    error InsufficientAttached(uint256 tokenId, uint256 attached, uint256 needed);
    error MigrationClosed();
    error LegacyCanvasNotPaused();
    error DelegationsSealed();
    error DelegationsNotFinalized();
    error MigrationNotFinalized();
    error InvalidSnapshot();
    error LengthMismatch();
    error AllowancesPaused();
    error MigrationTotalMismatch(uint256 expected, uint256 actual);
    error PixelsCoolingDown(address account, uint256 available, uint256 needed, uint64 unlockAt);
    error CooldownTooLong(uint64 cooldown, uint64 max);

    event AuthorizedWriterSet(address indexed writer, bool allowed);
    event TransformedImageDataSet(uint256 indexed tokenId, address pointer, uint256 length);
    event TransformCleared(uint256 indexed tokenId);
    event GridSizeSet(uint256 indexed tokenId, uint256 size);
    event BaseClearedSet(uint256 indexed tokenId, bool cleared);
    event DelegateSet(uint256 indexed tokenId, address indexed delegate, address setBy);
    event DelegateRevoked(uint256 indexed tokenId, address indexed previousDelegate);
    event DelegationsSeeded(uint256 count);
    event DelegationSnapshotFinalized(uint256 indexed snapshotBlock, uint256 snapshotTimestamp, uint256 count);
    event MoverRolesSet(address indexed mover, uint8 roles);
    /// @dev Zero address as `from` means a mint, zero address as `to` means a burn.
    event BalanceMoved(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event AllowancesPausedSet(bool paused);
    event CooldownSet(address indexed account, uint64 cooldown);
    event AttachedChanged(uint256 indexed tokenId, int256 delta, uint256 newAttached, uint8 reason);
    event TokenMigrated(uint256 indexed tokenId, uint256 legacyAmount);
    event MigrationFinalized(uint256 totalAttached);

    /// @notice May mint, burn, attach, detach and move attached pixels: the only role that changes supply.
    uint8 public constant ROLE_CANVAS = 1;
    /// @notice May move wallet balances (listings are escrowed in the market's own balance).
    uint8 public constant ROLE_MARKET = 2;
    /// @notice May move wallet balances (a wrapper locks pixels in its own balance). Helpful for a future ERC20 migration.
    uint8 public constant ROLE_WRAPPER = 4;

    struct Slot {
        address pointer;
        bool cleared;
    }

    INormiesCanvasStorage public immutable legacyStorage;
    /// @notice The original canvas whose action points migrateBatch copies in.
    INormiesCanvasV1 public immutable legacyCanvas;

    uint256 internal constant BASE_GRID = 40;

    mapping(uint256 => Slot) private _slots;
    mapping(address => bool) public authorizedWriters;

    mapping(uint256 => uint256) private _gridSize;
    mapping(uint256 => bool) public baseCleared;
    /// @notice Per-token canvas delegate (painting only) and the owner who set it; stale once the token moves.
    mapping(uint256 => address) public delegates;
    mapping(uint256 => address) public delegateSetBy;
    /// @notice Set by seedAndFinalizeDelegations, the only way delegations are copied in; nothing can copy after.
    bool public delegationsSeeded;
    /// @notice Block and timestamp read by the one-transaction delegation migration script.
    uint256 public delegationSnapshotBlock;
    uint256 public delegationSnapshotTimestamp;

    mapping(address => uint256) public balanceOf;

    /**
     * @notice Cooldown on wallet pixels. Pixels that just arrived in a wallet (withdrawn from a Normie, or bought on
     *         the market) cannot be deposited, listed or spent until the cooldown has passed. Default one minute.
     *
     *         Why: it makes atomic round trips impossible. Without it one transaction could list pixels for 1 wei,
     *         buy them back from another wallet and deposit them, moving pixels between wallets for free, or pull
     *         pixels out of a Normie and re-home them in the same block through a helper contract. One minute is
     *         nothing for a holder and everything for a contract that needs atomicity.
     *
     *         The owner can raise one address's cooldown up to MAX_COOLDOWN (seven days). That is meant for wrapper
     *         contracts: a contract that accumulates pixels to hand out an ERC20 would have to sit on every incoming
     *         pixel for a week before it could move it, which makes such a wrapper impractical without shutting
     *         anyone out. Holders are never affected by that lever: after the cooldown, however long, the pixels
     *         are free to deposit or sell, exactly as before. Burn rewards minted straight to a wallet, and balances
     *         held by the market or another mover, never cool down.
     */
    uint64 public constant DEFAULT_COOLDOWN = 1 minutes;
    uint64 public constant MAX_COOLDOWN = 7 days;
    /// @dev 0 means the default; the owner can only set a longer one, see setCooldown.
    mapping(address => uint64) private _cooldown;
    /// @notice Pixels still cooling in a wallet, and when they free up. Once unlockAt has passed nothing is locked.
    mapping(address => uint256) public lockedBalance;
    mapping(address => uint64) public unlockAt;
    /// @notice How many of `owner`'s wallet pixels `spender` may spend through the canvas or the market.
    mapping(address => mapping(address => uint256)) public allowance;
    /// @notice While set, nobody but its owner can use an allowance; approve (and so revoking) stays open.
    bool public allowancesPaused;
    mapping(uint256 => uint256) private _attached;
    /// @notice Tokens whose original balance has been copied in. Only meaningful until finalizeMigration.
    mapping(uint256 => bool) public migrated;
    mapping(address => uint8) public moverRoles;
    /// @notice Once set, migrateBatch is closed for good.
    bool public migrationFinalized;

    /// @notice Sum of all wallet balances.
    uint256 public totalWallet;
    /// @notice Sum of all attached balances.
    uint256 public totalAttached;

    constructor(INormiesCanvasStorage _legacyStorage, INormiesCanvasV1 _legacyCanvas) Lifebuoy() {
        _initializeOwner(msg.sender);
        legacyStorage = _legacyStorage;
        legacyCanvas = _legacyCanvas;
    }

    modifier onlyAuthorized() {
        require(msg.sender == owner() || authorizedWriters[msg.sender], NotAuthorized());
        _;
    }

    modifier onlyRole(uint8 roles) {
        require(moverRoles[msg.sender] & roles != 0, NotAuthorized());
        _;
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        authorizedWriters[writer] = allowed;
        emit AuthorizedWriterSet(writer, allowed);
    }

    /// @notice Grants or revokes mover roles (a bitmask of the ROLE_ constants, 0 revokes).
    function setMoverRoles(address mover, uint8 roles) external onlyOwner {
        require(mover != address(0), ZeroAddress());
        moverRoles[mover] = roles;
        emit MoverRolesSet(mover, roles);
    }

    /// @notice Kill switch for spending on someone else's behalf (deposits, paid services and listFrom through an
    ///         allowance). Holders acting for themselves are unaffected and can still change or revoke allowances.
    ///         A guardian or the owner switches it either way, at once.
    function setAllowancesPaused(bool paused) external onlyOwnerOrRoles(GUARDIAN_ROLE) {
        allowancesPaused = paused;
        emit AllowancesPausedSet(paused);
    }

    // ──────────────────────────────────────────────
    //  Overlays
    // ──────────────────────────────────────────────

    function setTransformedImageData(uint256 tokenId, bytes calldata imageData) external onlyAuthorized {
        address pointer = SSTORE2.write(imageData);
        _slots[tokenId] = Slot({ pointer: pointer, cleared: false });
        emit TransformedImageDataSet(tokenId, pointer, imageData.length);
    }

    function clearTransformedImageData(uint256 tokenId) external onlyAuthorized {
        _slots[tokenId] = Slot({ pointer: address(0), cleared: true });
        emit TransformCleared(tokenId);
    }

    function getTransformedImageData(uint256 tokenId) external view returns (bytes memory) {
        Slot memory slot = _slots[tokenId];
        if (slot.pointer != address(0)) return SSTORE2.read(slot.pointer);
        if (slot.cleared || address(legacyStorage) == address(0)) revert TokenNotTransformed(tokenId);
        return legacyStorage.getTransformedImageData(tokenId);
    }

    function isTransformed(uint256 tokenId) external view returns (bool) {
        Slot memory slot = _slots[tokenId];
        if (slot.pointer != address(0)) return true;
        if (slot.cleared || address(legacyStorage) == address(0)) return false;
        return legacyStorage.isTransformed(tokenId);
    }

    /// @notice True once a token has been written or cleared here (no longer reads the legacy storage).
    function isOwnedHere(uint256 tokenId) external view returns (bool) {
        Slot memory slot = _slots[tokenId];
        return slot.pointer != address(0) || slot.cleared;
    }

    // ──────────────────────────────────────────────
    //  Token state: grid size, blank base, delegate
    // ──────────────────────────────────────────────

    /// @notice Pixels per side of a token's canvas (40 unless enlarged).
    function gridSize(uint256 tokenId) external view returns (uint256) {
        uint256 size = _gridSize[tokenId];
        return size == 0 ? BASE_GRID : size;
    }

    function delegation(uint256 tokenId) external view returns (address delegate, address setBy) {
        return (delegates[tokenId], delegateSetBy[tokenId]);
    }

    function setGridSize(uint256 tokenId, uint256 size) external onlyRole(ROLE_CANVAS) {
        _gridSize[tokenId] = size;
        emit GridSizeSet(tokenId, size);
    }

    function setBaseCleared(uint256 tokenId, bool cleared) external onlyRole(ROLE_CANVAS) {
        baseCleared[tokenId] = cleared;
        emit BaseClearedSet(tokenId, cleared);
    }

    /// @notice Sets (or revokes) a token's delegate after migration is sealed. The canvas checks ownership.
    function setDelegate(uint256 tokenId, address delegate, address setBy) external onlyRole(ROLE_CANVAS) {
        require(delegationsSeeded, DelegationsNotFinalized());
        _setDelegate(tokenId, delegate, setBy);
    }

    /// @notice Burned ids can be minted again, so nothing per token may survive a burn.
    function resetTokenState(uint256 tokenId) external onlyRole(ROLE_CANVAS) {
        if (_gridSize[tokenId] != 0) {
            delete _gridSize[tokenId];
            emit GridSizeSet(tokenId, BASE_GRID);
        }
        if (baseCleared[tokenId]) {
            delete baseCleared[tokenId];
            emit BaseClearedSet(tokenId, false);
        }
        if (delegates[tokenId] != address(0)) _setDelegate(tokenId, address(0), address(0));
        Slot memory slot = _slots[tokenId];
        bool transformed = slot.pointer != address(0)
            || (!slot.cleared && address(legacyStorage) != address(0) && legacyStorage.isTransformed(tokenId));
        if (transformed) {
            _slots[tokenId] = Slot({ pointer: address(0), cleared: true });
            emit TransformCleared(tokenId);
        }
    }

    /**
     * @notice Copies the owner's complete delegation snapshot from the original canvas and seals it, in one
     *         transaction and only once. Records are copied exactly as they were there (delegate and the owner
     *         who set it), so a delegate that was live there stays live and one that went stale stays stale.
     *         The snapshot is taken when the script starts, not when this transaction is mined; later V1 changes
     *         deliberately do not propagate to V2. Requires finalized pixel balances and a paused original canvas.
     *         An empty snapshot is valid and still seals. There is no other way to copy or seal, so the copy can
     *         never be partial or empty by accident.
     */
    function seedAndFinalizeDelegations(
        uint256[] calldata tokenIds,
        address[] calldata delegates_,
        address[] calldata setBy,
        uint256 snapshotBlock,
        uint256 snapshotTimestamp
    ) external onlyOwner {
        require(!delegationsSeeded, DelegationsSealed());
        require(migrationFinalized, MigrationNotFinalized());
        require(legacyCanvas.paused(), LegacyCanvasNotPaused());
        require(snapshotBlock <= block.number && snapshotTimestamp <= block.timestamp, InvalidSnapshot());
        require(tokenIds.length == delegates_.length && tokenIds.length == setBy.length, LengthMismatch());
        for (uint256 i; i < tokenIds.length; i++) {
            _setDelegate(tokenIds[i], delegates_[i], setBy[i]);
        }
        emit DelegationsSeeded(tokenIds.length);
        delegationSnapshotBlock = snapshotBlock;
        delegationSnapshotTimestamp = snapshotTimestamp;
        delegationsSeeded = true;
        emit DelegationSnapshotFinalized(snapshotBlock, snapshotTimestamp, tokenIds.length);
    }

    function _setDelegate(uint256 tokenId, address delegate, address setBy) internal {
        if (delegate == address(0)) {
            address previous = delegates[tokenId];
            delete delegates[tokenId];
            delete delegateSetBy[tokenId];
            emit DelegateRevoked(tokenId, previous);
        } else {
            delegates[tokenId] = delegate;
            delegateSetBy[tokenId] = setBy;
            emit DelegateSet(tokenId, delegate, setBy);
        }
    }

    // ──────────────────────────────────────────────
    //  Pixels: views
    // ──────────────────────────────────────────────

    /// @notice Pixels attached to a token.
    function attachedOf(uint256 tokenId) public view returns (uint256) {
        return _attached[tokenId];
    }

    // ──────────────────────────────────────────────
    //  Pixels: migration from the original canvas
    // ──────────────────────────────────────────────

    /**
     * @notice Copies the original canvas balances of `tokenIds` in, reading each one from that canvas itself, so
     *         the caller cannot choose the amounts. Anyone may call it; a token is copied once. Only works while the
     *         original canvas is paused (so nothing there can still change), before the canvas or the market are
     *         unpaused; close it with finalizeMigration.
     */
    function migrateBatch(uint256[] calldata tokenIds) external {
        require(!migrationFinalized, MigrationClosed());
        require(legacyCanvas.paused(), LegacyCanvasNotPaused());
        for (uint256 i; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (migrated[tokenId]) continue;
            migrated[tokenId] = true;
            uint256 legacy = legacyCanvas.actionPoints(tokenId);
            if (legacy > 0) _creditAttached(tokenId, legacy, Reason.Migration);
            emit TokenMigrated(tokenId, legacy);
        }
    }

    /**
     * @notice Ends the copy. Irreversible, so it is a hard gate (audit C-M4): it only goes through when storage V2
     *         holds exactly `expectedTotalAttached`, the sum of the original canvas's action points over every id,
     *         read from it after it was paused. A partial copy cannot be sealed by mistake.
     */
    function finalizeMigration(uint256 expectedTotalAttached) external onlyOwner {
        require(!migrationFinalized, MigrationClosed());
        require(totalAttached == expectedTotalAttached, MigrationTotalMismatch(expectedTotalAttached, totalAttached));
        migrationFinalized = true;
        emit MigrationFinalized(totalAttached);
    }

    // ──────────────────────────────────────────────
    //  Pixels: allowances
    // ──────────────────────────────────────────────

    /// @notice Lets `spender` spend up to `amount` of the caller's pixels: list them, deposit them, or pay for a
    ///         canvas service with them, from the wallet or from a Normie the caller owns. An allowance is custody
    ///         of that amount (a spender can list at any price and fill the listing itself), so approve exactly what
    ///         is needed and revoke afterwards. type(uint256).max never decreases. Overwrites, like ERC20.
    function approve(address spender, uint256 amount) external {
        require(spender != address(0), ZeroAddress());
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    /// @notice Consumes `amount` of `owner`'s allowance to `spender`. Movers call it before spending pixels on behalf
    ///         of someone other than their caller; the owner spending their own pixels needs no allowance and is not
    ///         affected by the pause.
    function useAllowance(
        address owner,
        address spender,
        uint256 amount
    ) external onlyRole(ROLE_CANVAS | ROLE_MARKET | ROLE_WRAPPER) {
        if (owner == spender) return;
        require(!allowancesPaused, AllowancesPaused());
        uint256 allowed = allowance[owner][spender];
        require(allowed >= amount, InsufficientAllowance(owner, spender, allowed, amount));
        if (allowed != type(uint256).max) {
            unchecked {
                allowance[owner][spender] = allowed - amount;
            }
            emit Approval(owner, spender, allowed - amount);
        }
    }

    // ──────────────────────────────────────────────
    //  Pixels: cooldown
    // ──────────────────────────────────────────────

    /// @notice The cooldown applied to pixels arriving in `account`'s wallet. Movers (the market) have none.
    function cooldownOf(address account) public view returns (uint64) {
        if (moverRoles[account] != 0) return 0;
        uint64 custom = _cooldown[account];
        return custom == 0 ? DEFAULT_COOLDOWN : custom;
    }

    /// @notice Wallet pixels that can be deposited, listed or spent right now.
    function availableBalance(address account) public view returns (uint256) {
        uint256 bal = balanceOf[account];
        if (block.timestamp >= unlockAt[account]) return bal;
        uint256 locked = lockedBalance[account];
        return locked >= bal ? 0 : bal - locked;
    }

    /**
     * @notice Sets one address's cooldown, between the default and MAX_COOLDOWN. 0 restores the default.
     *         This exists for wrapper contracts (see the cooldown notice above); it can never shorten the default
     *         and never freezes anything: pixels always free up once the cooldown has run.
     */
    function setCooldown(address account, uint64 cooldown) external onlyOwner {
        require(account != address(0), ZeroAddress());
        require(cooldown <= MAX_COOLDOWN, CooldownTooLong(cooldown, MAX_COOLDOWN));
        require(cooldown == 0 || cooldown >= DEFAULT_COOLDOWN, CooldownTooLong(cooldown, MAX_COOLDOWN));
        _cooldown[account] = cooldown;
        emit CooldownSet(account, cooldown == 0 ? DEFAULT_COOLDOWN : cooldown);
    }

    // ──────────────────────────────────────────────
    //  Pixels: canvas role
    // ──────────────────────────────────────────────

    /// @dev Burn rewards: no cooldown, they were not withdrawn or bought.
    function mintTo(address to, uint256 amount) external onlyRole(ROLE_CANVAS) {
        require(to != address(0), ZeroAddress());
        _creditWallet(to, amount, false);
        totalWallet += amount;
        emit BalanceMoved(address(0), to, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyRole(ROLE_CANVAS) {
        _debitWallet(from, amount);
        totalWallet -= amount;
        emit BalanceMoved(from, address(0), amount);
    }

    function creditAttached(uint256 tokenId, uint256 amount, Reason reason) external onlyRole(ROLE_CANVAS) {
        _creditAttached(tokenId, amount, reason);
    }

    function debitAttached(uint256 tokenId, uint256 amount, Reason reason) external onlyRole(ROLE_CANVAS) {
        _debitAttached(tokenId, amount, reason);
    }

    /// @notice Moves attached pixels from one token to another (a burn's carry-over).
    function moveAttached(
        uint256 fromTokenId,
        uint256 toTokenId,
        uint256 amount,
        Reason reason
    ) external onlyRole(ROLE_CANVAS) {
        _debitAttached(fromTokenId, amount, reason);
        _creditAttached(toTokenId, amount, reason);
    }

    /// @notice Moves pixels from a wallet onto a token.
    function attach(address from, uint256 tokenId, uint256 amount, Reason reason) external onlyRole(ROLE_CANVAS) {
        _debitWallet(from, amount);
        totalWallet -= amount;
        emit BalanceMoved(from, address(0), amount);
        _creditAttached(tokenId, amount, reason);
    }

    /// @notice Moves pixels from a token into a wallet.
    function detach(uint256 tokenId, address to, uint256 amount, Reason reason) external onlyRole(ROLE_CANVAS) {
        require(to != address(0), ZeroAddress());
        _debitAttached(tokenId, amount, reason);
        _creditWallet(to, amount, true);
        totalWallet += amount;
        emit BalanceMoved(address(0), to, amount);
    }

    // ──────────────────────────────────────────────
    //  Pixels: any role
    // ──────────────────────────────────────────────

    /**
     * @notice Returns pixels the market holds in escrow to `to`, without a cooldown. Only the market, and only
     *         out of its own balance. Escrowed pixels were already past their cooldown when they were listed, so
     *         handing them back cools nothing; and since anyone may return an expired listing, a cooldown here would
     *         let a stranger restart the seller's.
     */
    function releaseEscrow(address to, uint256 amount) external onlyRole(ROLE_MARKET) {
        require(to != address(0), ZeroAddress());
        _debitWallet(msg.sender, amount);
        _creditWallet(to, amount, false);
        emit BalanceMoved(msg.sender, to, amount);
    }

    /// @notice A plain move between wallet balances. Supply does not change.
    function moveBalance(
        address from,
        address to,
        uint256 amount
    ) external onlyRole(ROLE_CANVAS | ROLE_MARKET | ROLE_WRAPPER) {
        require(to != address(0), ZeroAddress());
        _debitWallet(from, amount);
        _creditWallet(to, amount, true);
        emit BalanceMoved(from, to, amount);
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    /// @dev Only pixels past their cooldown can leave a wallet.
    function _debitWallet(address from, uint256 amount) internal {
        uint256 bal = balanceOf[from];
        require(bal >= amount, InsufficientBalance(from, bal, amount));
        uint256 available = availableBalance(from);
        require(available >= amount, PixelsCoolingDown(from, available, amount, unlockAt[from]));
        unchecked {
            balanceOf[from] = bal - amount;
        }
    }

    /// @dev Credits a wallet; `cools` starts (or extends) the cooldown on what just arrived. Pixels already past
    ///      their cooldown stay spendable: only the new arrivals, and anything still cooling, wait.
    function _creditWallet(address to, uint256 amount, bool cools) internal {
        balanceOf[to] += amount;
        if (!cools) return;
        uint64 cooldown = cooldownOf(to);
        if (cooldown == 0) return;
        lockedBalance[to] = (block.timestamp >= unlockAt[to] ? 0 : lockedBalance[to]) + amount;
        unlockAt[to] = uint64(block.timestamp) + cooldown;
    }

    function _creditAttached(uint256 tokenId, uint256 amount, Reason reason) internal {
        uint256 next = _attached[tokenId] + amount;
        _attached[tokenId] = next;
        totalAttached += amount;
        emit AttachedChanged(tokenId, int256(amount), next, uint8(reason));
    }

    function _debitAttached(uint256 tokenId, uint256 amount, Reason reason) internal {
        uint256 current = _attached[tokenId];
        require(current >= amount, InsufficientAttached(tokenId, current, amount));
        uint256 next;
        unchecked {
            next = current - amount;
        }
        _attached[tokenId] = next;
        totalAttached -= amount;
        emit AttachedChanged(tokenId, -int256(amount), next, uint8(reason));
    }
}

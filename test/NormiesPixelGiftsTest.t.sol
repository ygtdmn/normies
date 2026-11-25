// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { PixelMarketBase } from "./PixelMarketBase.t.sol";
import { NormiesArenaStorage } from "../src/NormiesArenaStorage.sol";
import { NormiesArenaQueue } from "../src/NormiesArenaQueue.sol";
import { NormiesArena } from "../src/NormiesArena.sol";
import { NormiesPixelGifts } from "../src/NormiesPixelGifts.sol";
import { NormiesCanvasStorageV2 } from "../src/NormiesCanvasStorageV2.sol";
import { DeployPixelGifts } from "../script/DeployPixelGifts.s.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/// @notice ERC-8004 adapter stand-in: agent `id` is bound to Normie `id` of `collection`, unless unbound.
contract GiftsAdapterMock {
    address internal immutable collection;
    mapping(uint256 => bool) public unbound;

    constructor(address collection_) {
        collection = collection_;
    }

    function unbind(uint256 agentId) external {
        unbound[agentId] = true;
    }

    function bindingOf(uint256 agentId) external view returns (uint8, address, uint256) {
        return (0, unbound[agentId] ? address(0) : collection, agentId);
    }
}

/// @notice NormiesPixelGifts against the real Normies collection, pixel ledger, canvas and Arena storage.
///         `user` is the gifter; `holder` holds Normie 7001 (registered in the Arena) and 7002 (not joined).
contract NormiesPixelGiftsTest is PixelMarketBase {
    event GiftedToWallet(address indexed from, address indexed to, uint256 amount);
    event GiftedToNormie(address indexed from, uint256 indexed id, uint256 amount);
    event GiftedToArena(address indexed from, uint256 indexed id, uint256 amount);

    NormiesArenaStorage store;
    NormiesArenaQueue queue;
    NormiesArena arena;
    GiftsAdapterMock adapter;
    NormiesPixelGifts gifts;

    address holder = address(0xA11CE);
    address receiver = address(0xCAFE);
    address guardian = address(0x6A2D);
    uint256 constant JOINED = 7001;
    uint256 constant LOOSE = 7002;
    uint256 role;

    function setUp() public override {
        super.setUp();
        adapter = new GiftsAdapterMock(address(normies));
        store = new NormiesArenaStorage(
            address(storageV2), address(normies), address(adapter), address(delegateV2), address(delegateV1), owner
        );
        arena = new NormiesArena(address(store), owner);
        queue = new NormiesArenaQueue(address(store), owner);
        store.setAuthorizedWriter(address(arena), true);
        store.setAuthorizedWriter(address(queue), true);
        storageV2.setMoverRoles(address(store), storageV2.ROLE_WRAPPER());
        storageV2.setMoverRoles(address(queue), storageV2.ROLE_WRAPPER());
        arena.setPaused(false);
        queue.setPaused(false);

        _mintRealTo(holder, JOINED);
        _mintRealTo(holder, LOOSE);
        vm.startPrank(holder);
        queue.bindAgent(JOINED, JOINED);
        queue.join(JOINED);
        vm.stopPrank();

        // The runbook's three wiring calls.
        gifts = new NormiesPixelGifts(address(store), owner);
        role = gifts.GIFTER_ROLE();
        storageV2.setMoverRoles(address(gifts), storageV2.ROLE_CANVAS());
        store.setAuthorizedWriter(address(gifts), true);
        gifts.grantRoles(user, role);
        gifts.grantRoles(guardian, 1);

        // Burn rewards: no cooldown.
        storageV2.mintTo(user, 100);
    }

    function _supply() internal view returns (uint256) {
        return storageV2.totalWallet() + storageV2.totalAttached();
    }

    // ──────────────────────────────────────────────
    //  Deployment
    // ──────────────────────────────────────────────

    function testReadsTheLedgerFromTheArenaStorage() public view {
        assertEq(address(gifts.pixels()), address(storageV2));
        assertEq(address(gifts.store()), address(store));
        assertEq(gifts.owner(), owner);
        assertEq(role, 32);
        assertFalse(gifts.paused());
    }

    function testConstructorRefusesZeroAddresses() public {
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        new NormiesPixelGifts(address(store), address(0));
        vm.expectRevert();
        new NormiesPixelGifts(address(0), owner);
    }

    function testDeployScriptHandsEverythingToTheAdmin() public {
        vm.setEnv("ARENA_STORAGE", vm.toString(address(store)));
        vm.setEnv("PIXEL_GIFTS_ADMIN", vm.toString(holder));
        NormiesPixelGifts deployed = new DeployPixelGifts().run();
        assertEq(deployed.owner(), holder);
        assertEq(address(deployed.store()), address(store));
        assertEq(address(deployed.pixels()), address(storageV2));
        // The deployer's rescue access is locked; only the owner can rescue.
        assertEq(deployed.rescueLocked(), 1);
        assertEq(storageV2.moverRoles(address(deployed)), 0);
        assertFalse(store.authorizedWriters(address(deployed)));
    }

    // ──────────────────────────────────────────────
    //  Who can give
    // ──────────────────────────────────────────────

    function testOnlyTheGifterRoleCanGive() public {
        storageV2.mintTo(buyer, 10);
        storageV2.mintTo(owner, 10);
        address[2] memory others = [buyer, owner]; // not even the owner, until it grants itself the role
        for (uint256 i; i < others.length; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(Ownable.Unauthorized.selector);
            gifts.giftToWallet(receiver, 1);
            vm.expectRevert(Ownable.Unauthorized.selector);
            gifts.giftToNormie(JOINED, 1);
            vm.expectRevert(Ownable.Unauthorized.selector);
            gifts.giftToArena(JOINED, 1);
            vm.stopPrank();
        }
    }

    function testAnAllowanceGivesNoOneAccessToTheGiftersPixels() public {
        vm.prank(user);
        storageV2.approve(buyer, type(uint256).max);
        vm.prank(buyer);
        vm.expectRevert(Ownable.Unauthorized.selector);
        gifts.giftToWallet(buyer, 1);
    }

    function testRevokingTheRoleStopsTheWallet() public {
        gifts.revokeRoles(user, role);
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        gifts.giftToWallet(receiver, 1);
    }

    function testPauseStopsEveryGift() public {
        vm.prank(buyer);
        vm.expectRevert(Ownable.Unauthorized.selector);
        gifts.setPaused(true);
        vm.prank(guardian);
        gifts.setPaused(true);
        vm.startPrank(user);
        vm.expectRevert(NormiesPixelGifts.Paused.selector);
        gifts.giftToWallet(receiver, 1);
        vm.expectRevert(NormiesPixelGifts.Paused.selector);
        gifts.giftToNormie(JOINED, 1);
        vm.expectRevert(NormiesPixelGifts.Paused.selector);
        gifts.giftToArena(JOINED, 1);
        vm.stopPrank();
        gifts.setPaused(false);
        vm.prank(user);
        gifts.giftToWallet(receiver, 1);
    }

    // ──────────────────────────────────────────────
    //  To a wallet
    // ──────────────────────────────────────────────

    function testGiftToWalletMovesTheGiftersOwnPixels() public {
        uint256 supply = _supply();
        vm.expectEmit(address(gifts));
        emit GiftedToWallet(user, receiver, 30);
        vm.prank(user);
        gifts.giftToWallet(receiver, 30);
        assertEq(storageV2.balanceOf(user), 70);
        assertEq(storageV2.balanceOf(receiver), 30);
        assertEq(storageV2.balanceOf(address(gifts)), 0);
        assertEq(_supply(), supply);
    }

    function testGiftedWalletPixelsCoolDownLikeBoughtOnes() public {
        gifts.grantRoles(receiver, role);
        vm.prank(user);
        gifts.giftToWallet(receiver, 30);
        assertEq(storageV2.availableBalance(receiver), 0);
        assertEq(storageV2.lockedBalance(receiver), 30);

        // Still cooling: they cannot be given on, attached or sent to the Arena.
        uint64 unlock = storageV2.unlockAt(receiver);
        bytes memory cooling =
            abi.encodeWithSelector(NormiesCanvasStorageV2.PixelsCoolingDown.selector, receiver, 0, 30, unlock);
        vm.startPrank(receiver);
        vm.expectRevert(cooling);
        gifts.giftToWallet(buyer, 30);
        vm.expectRevert(cooling);
        gifts.giftToNormie(JOINED, 30);
        vm.expectRevert(cooling);
        gifts.giftToArena(JOINED, 30);
        vm.stopPrank();

        _cool();
        vm.prank(receiver);
        gifts.giftToWallet(buyer, 30);
        assertEq(storageV2.balanceOf(receiver), 0);
    }

    function testGiftToWalletRefusesBadInput() public {
        vm.startPrank(user);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToWallet(address(0), 1);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToWallet(user, 1);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToWallet(receiver, 0);
        vm.expectRevert();
        gifts.giftToWallet(receiver, 101);
        vm.stopPrank();
        assertEq(storageV2.balanceOf(user), 100);
    }

    function testGiftToWalletRefusesLedgerMovers() public {
        address[5] memory movers = [address(market), address(canvas), address(store), address(queue), address(gifts)];
        vm.startPrank(user);
        for (uint256 i; i < movers.length; ++i) {
            vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
            gifts.giftToWallet(movers[i], 1);
        }
        vm.stopPrank();
    }

    function testGiftToWalletBatch() public {
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (tos[0], tos[1]) = (receiver, buyer);
        (amounts[0], amounts[1]) = (10, 20);
        uint256 buyerBefore = storageV2.balanceOf(buyer);
        vm.prank(user);
        gifts.giftToWalletBatch(tos, amounts);
        assertEq(storageV2.balanceOf(receiver), 10);
        assertEq(storageV2.balanceOf(buyer), buyerBefore + 20);
        assertEq(storageV2.balanceOf(user), 70);
    }

    function testBatchesRefuseBadShapesAndRevertWhole() public {
        address[] memory tos = new address[](2);
        uint256[] memory two = new uint256[](2);
        uint256[] memory one = new uint256[](1);
        (tos[0], tos[1]) = (receiver, address(0));
        uint256[] memory amounts = new uint256[](2);
        (two[0], two[1]) = (JOINED, 10_000);
        (amounts[0], amounts[1]) = (1, 1);
        vm.startPrank(user);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToWalletBatch(tos, one);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToWalletBatch(new address[](0), new uint256[](0));
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToWalletBatch(new address[](101), new uint256[](101));
        // The second entry is bad: the first is not given either.
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToWalletBatch(tos, amounts);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToNormieBatch(two, amounts);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToArenaBatch(two, amounts);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToNormieBatch(two, one);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToArenaBatch(two, one);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToNormieBatch(new uint256[](101), new uint256[](101));
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToArenaBatch(new uint256[](0), new uint256[](0));
        vm.stopPrank();
        assertEq(storageV2.balanceOf(user), 100);
        assertEq(storageV2.balanceOf(receiver), 0);
        assertEq(storageV2.attachedOf(JOINED), 0);
        assertEq(store.balanceOf(JOINED), 0);
    }

    // ──────────────────────────────────────────────
    //  To a Normie's canvas
    // ──────────────────────────────────────────────

    function testGiftToNormieAttachesPixelsToSomeoneElsesNormie() public {
        uint256 supply = _supply();
        uint256 wallet = storageV2.totalWallet();
        vm.expectEmit(address(gifts));
        emit GiftedToNormie(user, LOOSE, 25);
        vm.prank(user);
        gifts.giftToNormie(LOOSE, 25);
        assertEq(storageV2.attachedOf(LOOSE), 25);
        assertEq(canvas.actionPoints(LOOSE), 25);
        assertEq(storageV2.balanceOf(user), 75);
        assertEq(storageV2.totalWallet(), wallet - 25);
        assertEq(_supply(), supply);
    }

    function testAGiftedNormieBudgetIsItsHoldersToWithdraw() public {
        vm.prank(user);
        gifts.giftToNormie(LOOSE, 25);
        // The gifter cannot take it back through the canvas.
        vm.prank(user);
        vm.expectRevert();
        canvas.withdrawPixels(LOOSE, 25, false);
        vm.prank(holder);
        canvas.withdrawPixels(LOOSE, 10, false);
        assertEq(storageV2.balanceOf(holder), 10);
        assertEq(storageV2.attachedOf(LOOSE), 15);
    }

    function testGiftToNormieRefusesBurnedAndUnknownNormies() public {
        vm.prank(holder);
        normies.burn(LOOSE);
        vm.startPrank(user);
        vm.expectRevert(NormiesPixelGifts.Burned.selector);
        gifts.giftToNormie(LOOSE, 5);
        vm.expectRevert(NormiesPixelGifts.Burned.selector);
        gifts.giftToNormie(8888, 5); // never minted
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToNormie(10_000, 5);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToNormie(JOINED, 0);
        vm.expectRevert();
        gifts.giftToNormie(JOINED, 101);
        vm.stopPrank();
        assertEq(storageV2.balanceOf(user), 100);
    }

    function testGiftToNormieBatch() public {
        uint256[] memory ids = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (JOINED, LOOSE, JOINED);
        (amounts[0], amounts[1], amounts[2]) = (10, 20, 30);
        vm.prank(user);
        gifts.giftToNormieBatch(ids, amounts);
        assertEq(storageV2.attachedOf(JOINED), 40);
        assertEq(storageV2.attachedOf(LOOSE), 20);
        assertEq(storageV2.balanceOf(user), 40);
        // A canvas gift is not an Arena gift.
        assertEq(store.balanceOf(JOINED), 0);
    }

    // ──────────────────────────────────────────────
    //  To a Normie's Arena balance
    // ──────────────────────────────────────────────

    function testGiftToArenaCreditsARegisteredNormieOfSomeoneElse() public {
        uint256 supply = _supply();
        vm.expectEmit(address(gifts));
        emit GiftedToArena(user, JOINED, 25);
        vm.prank(user);
        gifts.giftToArena(JOINED, 25);
        assertEq(store.balanceOf(JOINED), 25);
        assertEq(store.stateOf(JOINED), store.STATE_ACTIVE());
        assertEq(store.totalAllocated(), 25);
        assertEq(storageV2.balanceOf(address(store)), 25);
        assertEq(storageV2.balanceOf(user), 75);
        assertEq(storageV2.balanceOf(address(gifts)), 0);
        assertEq(storageV2.attachedOf(JOINED), 0);
        assertEq(store.surplus(), 0);
        assertEq(_supply(), supply);

        // The balance is the holder's: the gifter cannot take it back, the holder withdraws it.
        vm.prank(user);
        vm.expectRevert(NormiesArenaStorage.Forbidden.selector);
        store.withdraw(JOINED, 25);
        vm.prank(holder);
        store.withdraw(JOINED, 25);
        assertEq(storageV2.balanceOf(holder), 25);
        assertEq(store.totalAllocated(), 0);
    }

    function testGiftToArenaNeverRegistersANormie() public {
        uint256 registered = store.registeredCount();
        vm.prank(user);
        gifts.giftToArena(LOOSE, 25);
        assertEq(store.balanceOf(LOOSE), 25);
        assertEq(store.stateOf(LOOSE), store.STATE_UNREGISTERED());
        assertFalse(store.isRegistered(LOOSE));
        assertEq(store.registeredCount(), registered);

        // Its holder can withdraw part of it, then join and keep the rest as its Arena balance.
        vm.startPrank(holder);
        store.withdraw(LOOSE, 5);
        queue.bindAgent(LOOSE, LOOSE);
        queue.join(LOOSE);
        vm.stopPrank();
        assertEq(storageV2.balanceOf(holder), 5);
        assertEq(store.balanceOf(LOOSE), 20);
        assertEq(store.stateOf(LOOSE), store.STATE_ACTIVE());
    }

    function testGiftToArenaBringsAShortNormieBack() public {
        // Round 1 becomes a paid round: the joined Normie has nothing, so it sits out.
        arena.setFreeRound(1, false);
        arena.setFreeRound(2, false);
        uint256 price = arena.entryPrice();
        arena.startRound(1);
        assertEq(store.stateOf(JOINED), store.STATE_SHORT());

        vm.prank(user);
        gifts.giftToArena(JOINED, price);
        assertEq(store.stateOf(JOINED), store.STATE_ACTIVE());
        assertFalse(store.isPlayer(JOINED)); // not the round already open

        uint256[] memory none;
        arena.endRound(1, none, none, none);
        arena.startRound(2);
        assertTrue(store.isPlayer(JOINED));
        assertEq(store.balanceOf(JOINED), 0);
    }

    function testGiftToArenaSkipsTheAgentLinkCheck() public {
        adapter.unbind(JOINED);
        storageV2.mintTo(holder, 5);
        vm.prank(holder);
        vm.expectRevert(); // the holder's own top-up still needs the link
        queue.deposit(JOINED, 5);
        vm.prank(user);
        gifts.giftToArena(JOINED, 5);
        assertEq(store.balanceOf(JOINED), 5);
    }

    function testGiftToArenaRefusesBurnedAndClearedNormies() public {
        vm.prank(holder);
        normies.burn(JOINED);
        vm.prank(user);
        vm.expectRevert(NormiesPixelGifts.Burned.selector);
        gifts.giftToArena(JOINED, 5);
        store.clear(JOINED);
        vm.prank(user);
        vm.expectRevert(NormiesPixelGifts.Burned.selector);
        gifts.giftToArena(JOINED, 5);
        // A Normie parked on the dead address counts as burned too.
        vm.prank(holder);
        normies.transferFrom(holder, 0x000000000000000000000000000000000000dEaD, LOOSE);
        vm.startPrank(user);
        vm.expectRevert(NormiesPixelGifts.Burned.selector);
        gifts.giftToArena(LOOSE, 5);
        vm.expectRevert(NormiesPixelGifts.Burned.selector);
        gifts.giftToNormie(LOOSE, 5);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToArena(10_000, 5);
        vm.expectRevert(NormiesPixelGifts.InvalidInput.selector);
        gifts.giftToArena(LOOSE, 0);
        vm.stopPrank();
        assertEq(storageV2.balanceOf(user), 100);
        assertEq(storageV2.balanceOf(address(store)), 0);
    }

    function testGiftToArenaBatch() public {
        uint256[] memory ids = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (JOINED, LOOSE, JOINED);
        (amounts[0], amounts[1], amounts[2]) = (10, 20, 30);
        vm.prank(user);
        gifts.giftToArenaBatch(ids, amounts);
        assertEq(store.balanceOf(JOINED), 40);
        assertEq(store.balanceOf(LOOSE), 20);
        assertEq(store.totalAllocated(), 60);
        assertEq(storageV2.balanceOf(address(store)), 60);
        assertEq(storageV2.balanceOf(user), 40);
    }

    // ──────────────────────────────────────────────
    //  Wiring
    // ──────────────────────────────────────────────

    function testNothingMovesWithoutTheLedgerRole() public {
        storageV2.setMoverRoles(address(gifts), 0);
        vm.startPrank(user);
        vm.expectRevert();
        gifts.giftToWallet(receiver, 1);
        vm.expectRevert();
        gifts.giftToNormie(JOINED, 1);
        vm.expectRevert();
        gifts.giftToArena(JOINED, 1);
        vm.stopPrank();
        assertEq(storageV2.balanceOf(user), 100);
    }

    function testCanvasGiftsNeedTheCanvasRole() public {
        // With the wrapper role only, wallet and Arena gifts work but a canvas gift does not.
        storageV2.setMoverRoles(address(gifts), storageV2.ROLE_WRAPPER());
        vm.startPrank(user);
        gifts.giftToWallet(receiver, 1);
        gifts.giftToArena(JOINED, 1);
        vm.expectRevert();
        gifts.giftToNormie(JOINED, 1);
        vm.stopPrank();
    }

    function testArenaGiftsNeedTheWriterFlagButTheOthersDoNot() public {
        store.setAuthorizedWriter(address(gifts), false);
        vm.startPrank(user);
        vm.expectRevert(NormiesArenaStorage.NotAuthorized.selector);
        gifts.giftToArena(JOINED, 1);
        gifts.giftToWallet(receiver, 1);
        gifts.giftToNormie(JOINED, 1);
        vm.stopPrank();
        assertEq(storageV2.balanceOf(user), 98);
        assertEq(storageV2.balanceOf(address(store)), 0);
    }

    /// @notice Full batches to distinct Normies, storage cold. RUN WITH --isolate for the real figures.
    function testMaxBatchGas() public {
        uint256 n = gifts.MAX_BATCH();
        uint256[] memory ids = new uint256[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = 7100 + i;
            amounts[i] = 1;
            normies.mint(address(uint160(0x1000 + i)), 7100 + i);
        }
        storageV2.mintTo(user, 100);
        vm.cool(address(storageV2));
        vm.cool(address(store));
        vm.cool(address(gifts));
        vm.cool(address(normies));
        vm.prank(user);
        uint256 before = gasleft();
        gifts.giftToArenaBatch(ids, amounts);
        uint256 used = before - gasleft();
        emit log_named_uint("MAX_BATCH giftToArenaBatch gas, cold", used);
        assertLt(used, 14_000_000);
        vm.prank(user);
        before = gasleft();
        gifts.giftToNormieBatch(ids, amounts);
        used = before - gasleft();
        emit log_named_uint("MAX_BATCH giftToNormieBatch gas", used);
        assertLt(used, 14_000_000);
    }

    function testFuzzGiftsConservePixels(uint8 amount, uint8 kind) public {
        vm.assume(amount > 0 && amount <= 100);
        uint256 supply = _supply();
        vm.prank(user);
        if (kind % 3 == 0) gifts.giftToWallet(receiver, amount);
        else if (kind % 3 == 1) gifts.giftToNormie(LOOSE, amount);
        else gifts.giftToArena(LOOSE, amount);
        assertEq(storageV2.balanceOf(user), 100 - uint256(amount));
        assertEq(storageV2.balanceOf(receiver) + storageV2.attachedOf(LOOSE) + store.balanceOf(LOOSE), uint256(amount));
        assertEq(_supply(), supply);
        assertEq(store.surplus(), 0);
    }
}

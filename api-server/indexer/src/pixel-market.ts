import { ponder } from "ponder:registry";
import {
  burnCommitment,
  canvasSinkEvent,
  canvasTokenState,
  delegation,
  marketFill,
  marketListing,
  marketStats,
  pixelBalance,
  pixelLedgerEvent,
  pixelSupply,
  pixelTransform,
  tokenData,
  zombieTokenState,
} from "ponder:schema";
import { hexToBytes, parseAbi } from "viem";
import {
  ZERO_ADDRESS,
  bytesForGrid,
  compositeBytes,
  countPixels,
  embedCentered,
  eventMeta,
  gridSizeFromLength,
  upsertCanvasState,
  type EventMeta,
  type IndexingContext,
} from "./lib/canvas-state.js";

// ──────────────────────────────────────────────
//  Pixel Market (V2 stack) handlers: ledger, canvas V2, storage V2, market.
//  V1 handlers live in src/index.ts and keep running for history.
// ──────────────────────────────────────────────

const GLOBAL_ID = "global";
const REASONS = ["migration", "burnReward", "burnTransfer", "deposit", "withdraw", "spend"] as const;
const SOURCES = ["wallet", "attached"] as const;

const commitPixelCountsABI = parseAbi([
  "function commitPixelCounts(uint256 commitId) view returns (uint256[])",
]);
const getTransformedImageDataABI = parseAbi([
  "function getTransformedImageData(uint256 tokenId) view returns (bytes)",
]);

function reasonName(reason: number): string {
  return REASONS[reason] ?? `unknown-${reason}`;
}

function sourceName(source: number): string {
  return SOURCES[source] ?? `unknown-${source}`;
}

async function adjustBalance(
  context: IndexingContext,
  address: `0x${string}`,
  delta: bigint,
  meta: EventMeta,
): Promise<void> {
  if (address === ZERO_ADDRESS) return;
  const existing = await context.db.find(pixelBalance, { address });
  const balance = (existing?.balance ?? 0n) + delta;
  await context.db
    .insert(pixelBalance)
    .values({ address, balance, updatedBlock: meta.blockNumber })
    .onConflictDoUpdate({ balance, updatedBlock: meta.blockNumber });
}

async function adjustSupply(
  context: IndexingContext,
  delta: { wallet?: bigint; attached?: bigint; migrated?: number },
  meta: EventMeta,
): Promise<void> {
  const existing = await context.db.find(pixelSupply, { id: GLOBAL_ID });
  const next = {
    id: GLOBAL_ID,
    totalWallet: (existing?.totalWallet ?? 0n) + (delta.wallet ?? 0n),
    totalAttached: (existing?.totalAttached ?? 0n) + (delta.attached ?? 0n),
    totalMigrated: (existing?.totalMigrated ?? 0) + (delta.migrated ?? 0),
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
  };
  await context.db.insert(pixelSupply).values(next).onConflictDoUpdate({
    totalWallet: next.totalWallet,
    totalAttached: next.totalAttached,
    totalMigrated: next.totalMigrated,
    blockNumber: next.blockNumber,
    timestamp: next.timestamp,
  });
}

async function patchMarketStats(
  context: IndexingContext,
  patch: (current: {
    volumeWei: bigint;
    feesWei: bigint;
    feesCollectedWei: bigint;
    pixelsTraded: bigint;
    fills: number;
    listings: number;
    feeBps: number;
    revenueShareBps: number;
    paused: boolean;
  }) => Partial<{
    volumeWei: bigint;
    feesWei: bigint;
    feesCollectedWei: bigint;
    pixelsTraded: bigint;
    fills: number;
    listings: number;
    feeBps: number;
    revenueShareBps: number;
    paused: boolean;
  }>,
  meta: EventMeta,
): Promise<void> {
  const existing = await context.db.find(marketStats, { id: GLOBAL_ID });
  const current = {
    volumeWei: existing?.volumeWei ?? 0n,
    feesWei: existing?.feesWei ?? 0n,
    feesCollectedWei: existing?.feesCollectedWei ?? 0n,
    pixelsTraded: existing?.pixelsTraded ?? 0n,
    fills: existing?.fills ?? 0,
    listings: existing?.listings ?? 0,
    feeBps: existing?.feeBps ?? 1000,
    revenueShareBps: existing?.revenueShareBps ?? 5000,
    paused: existing?.paused ?? true,
  };
  const next = { ...current, ...patch(current), id: GLOBAL_ID, blockNumber: meta.blockNumber, timestamp: meta.timestamp };
  await context.db.insert(marketStats).values(next).onConflictDoUpdate({
    volumeWei: next.volumeWei,
    feesWei: next.feesWei,
    feesCollectedWei: next.feesCollectedWei,
    pixelsTraded: next.pixelsTraded,
    fills: next.fills,
    listings: next.listings,
    feeBps: next.feeBps,
    revenueShareBps: next.revenueShareBps,
    paused: next.paused,
    blockNumber: next.blockNumber,
    timestamp: next.timestamp,
  });
}

/**
 * The art an overlay is composited onto, embedded into the token's grid:
 * the zombie bitmap for zombies, otherwise the decrypted mint art from
 * token_data; empty when the base has been cleared. Null when unknown.
 */
async function baseBitmap(
  context: IndexingContext,
  tokenId: bigint,
  gridSize: number,
  cleared: boolean,
): Promise<Uint8Array | null> {
  if (cleared) return new Uint8Array(bytesForGrid(gridSize));
  const zombie = await context.db.find(zombieTokenState, { tokenId });
  let raw: `0x${string}` | null = null;
  if (zombie?.isZombie && zombie.bitmap) {
    raw = zombie.bitmap;
  } else {
    const data = await context.db.find(tokenData, { tokenId });
    raw = data?.rawImageData ?? null;
  }
  if (!raw) return null;
  return embedCentered(hexToBytes(raw), 40, gridSize);
}

// ──────────────────────────────────────────────
//  Ledger
// ──────────────────────────────────────────────

ponder.on("NormiesCanvasStorageV2:BalanceMoved", async ({ event, context }) => {
  const { from, to, amount } = event.args;
  const meta = eventMeta(event);

  await adjustBalance(context, from, -amount, meta);
  await adjustBalance(context, to, amount, meta);

  let walletDelta = 0n;
  if (from === ZERO_ADDRESS) walletDelta += amount;
  if (to === ZERO_ADDRESS) walletDelta -= amount;
  if (walletDelta !== 0n) await adjustSupply(context, { wallet: walletDelta }, meta);

  await context.db.insert(pixelLedgerEvent).values({
    id: `${event.block.number}-${event.log.logIndex}`,
    kind: "move",
    from,
    to,
    tokenId: null,
    amount,
    newAttached: null,
    reason: null,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    logIndex: Number(event.log.logIndex),
  });
});

ponder.on("NormiesCanvasStorageV2:AttachedChanged", async ({ event, context }) => {
  const { tokenId, delta, newAttached, reason } = event.args;
  const meta = eventMeta(event);

  // The ledger emits AttachedChanged(Migration) before TokenMigrated, so the
  // migrated flag and the migrated count are owned by the TokenMigrated handler.
  await upsertCanvasState(context, tokenId, { actionPoints: newAttached }, meta);
  await adjustSupply(context, { attached: delta }, meta);

  await context.db.insert(pixelLedgerEvent).values({
    id: `${event.block.number}-${event.log.logIndex}`,
    kind: "attached",
    from: null,
    to: null,
    tokenId,
    amount: delta < 0n ? -delta : delta,
    newAttached,
    reason: reasonName(Number(reason)),
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    logIndex: Number(event.log.logIndex),
  });
});

ponder.on("NormiesCanvasStorageV2:TokenMigrated", async ({ event, context }) => {
  const { tokenId } = event.args;
  const meta = eventMeta(event);
  const existing = await context.db.find(canvasTokenState, { tokenId });
  if (!existing?.migrated) await adjustSupply(context, { migrated: 1 }, meta);
  await upsertCanvasState(context, tokenId, { migrated: true }, meta);
});

// ──────────────────────────────────────────────
//  Canvas V2: delegation
// ──────────────────────────────────────────────

ponder.on("NormiesCanvasStorageV2:DelegateSet", async ({ event, context }) => {
  // setBy comes from the event: a seeded delegation carries the owner who set it on the original canvas, and a
  // smart wallet's tx.from would be its relayer.
  const { tokenId, delegate, setBy: delegateSetBy } = event.args;
  const meta = eventMeta(event);

  await context.db
    .insert(delegation)
    .values({ tokenId, delegate })
    .onConflictDoUpdate(() => ({ delegate }));
  await upsertCanvasState(context, tokenId, { delegate, delegateSetBy }, meta);
});

ponder.on("NormiesCanvasStorageV2:DelegateRevoked", async ({ event, context }) => {
  const { tokenId } = event.args;
  await context.db.delete(delegation, { tokenId });
  await upsertCanvasState(
    context,
    tokenId,
    { delegate: ZERO_ADDRESS, delegateSetBy: ZERO_ADDRESS },
    eventMeta(event),
  );
});

// ──────────────────────────────────────────────
//  Canvas V2: burns
// ──────────────────────────────────────────────

ponder.on("NormiesCanvasV2:BurnCommitted", async ({ event, context }) => {
  const { commitId, owner, receiverTokenId, tokenCount, transferredActionPoints, toWallet } = event.args;

  let pixelCountsJson: string | undefined;
  try {
    const pixelCounts = await context.client.readContract({
      address: event.log.address,
      abi: commitPixelCountsABI,
      functionName: "commitPixelCounts",
      args: [commitId],
    });
    pixelCountsJson = JSON.stringify(pixelCounts.map(Number));
  } catch {
    // Non-critical: pixel counts stay readable through the contract view.
  }

  await context.db.insert(burnCommitment).values({
    id: `2-${commitId}`,
    commitId,
    contractVersion: 2,
    owner,
    receiverTokenId,
    toWallet,
    tokenCount: Number(tokenCount),
    transferredActionPoints,
    pixelCounts: pixelCountsJson,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    revealed: false,
  });
});

// Attached balances come from the ledger's AttachedChanged, so a V2 reveal only
// closes the commitment row.
ponder.on("NormiesCanvasV2:BurnRevealed", async ({ event, context }) => {
  const { commitId, totalActions, expired } = event.args;
  await context.db.update(burnCommitment, { id: `2-${commitId}` }).set({
    revealed: true,
    totalActions,
    expired,
    revealBlockNumber: event.block.number,
    revealTimestamp: event.block.timestamp,
    revealTxHash: event.transaction.hash,
  });
});

// ──────────────────────────────────────────────
//  Storage V2 + Canvas V2: overlays
//
//  The storage event is the source of truth for the bitmap (it fires for bot
//  writes too). When the canvas is the writer, PixelsTransformed follows in the
//  same tx and refines transformer + counts on the same row.
// ──────────────────────────────────────────────

function transformRowId(txHash: `0x${string}`, tokenId: bigint): string {
  return `${txHash}-${tokenId}`;
}

ponder.on("NormiesCanvasStorageV2:TransformedImageDataSet", async ({ event, context }) => {
  const { tokenId } = event.args;
  const meta = eventMeta(event);

  const bitmap = (await context.client.readContract({
    address: event.log.address,
    abi: getTransformedImageDataABI,
    functionName: "getTransformedImageData",
    args: [tokenId],
  })) as `0x${string}`;
  const bytes = hexToBytes(bitmap);
  const gridSize = gridSizeFromLength(bytes.length);
  const locked = countPixels(bytes, gridSize);

  const state = await context.db.find(canvasTokenState, { tokenId });
  const base = await baseBitmap(context, tokenId, gridSize, state?.baseCleared ?? false);
  const newPixelCount = base ? countPixels(compositeBytes(base, bytes), gridSize) : locked;

  await context.db
    .insert(pixelTransform)
    .values({
      id: transformRowId(event.transaction.hash, tokenId),
      tokenId,
      transformer: event.transaction.from,
      changeCount: locked,
      newPixelCount,
      transformBitmap: bitmap,
      gridSize,
      cleared: false,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    })
    .onConflictDoUpdate({
      transformBitmap: bitmap,
      changeCount: locked,
      newPixelCount,
      gridSize,
      cleared: false,
    });

  await upsertCanvasState(
    context,
    tokenId,
    { customized: true, latestTransformBitmap: bitmap, lockedPixels: locked },
    meta,
  );
});

ponder.on("NormiesCanvasStorageV2:TransformCleared", async ({ event, context }) => {
  const { tokenId } = event.args;
  const meta = eventMeta(event);

  const state = await context.db.find(canvasTokenState, { tokenId });
  const gridSize = state?.gridSize ?? 40;
  const base = await baseBitmap(context, tokenId, gridSize, state?.baseCleared ?? false);

  await context.db
    .insert(pixelTransform)
    .values({
      id: `${transformRowId(event.transaction.hash, tokenId)}-clear`,
      tokenId,
      transformer: event.transaction.from,
      changeCount: 0,
      newPixelCount: base ? countPixels(base, gridSize) : 0,
      transformBitmap: null,
      gridSize,
      cleared: true,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();

  await upsertCanvasState(
    context,
    tokenId,
    { customized: false, latestTransformBitmap: null, lockedPixels: 0 },
    meta,
  );
});

ponder.on("NormiesCanvasV2:PixelsTransformed", async ({ event, context }) => {
  const { transformer, tokenId, changeCount, newPixelCount } = event.args;
  const id = transformRowId(event.transaction.hash, tokenId);
  const existing = await context.db.find(pixelTransform, { id });
  if (existing) {
    await context.db.update(pixelTransform, { id }).set({
      transformer,
      changeCount: Number(changeCount),
      newPixelCount: Number(newPixelCount),
    });
  } else {
    // Storage event missing (should not happen): record what the canvas told us.
    const state = await context.db.find(canvasTokenState, { tokenId });
    await context.db.insert(pixelTransform).values({
      id,
      tokenId,
      transformer,
      changeCount: Number(changeCount),
      newPixelCount: Number(newPixelCount),
      transformBitmap: state?.latestTransformBitmap ?? null,
      gridSize: state?.gridSize ?? 40,
      cleared: false,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    });
  }
  await upsertCanvasState(
    context,
    tokenId,
    { customized: true, lockedPixels: Number(changeCount) },
    eventMeta(event),
  );
});

// ──────────────────────────────────────────────
//  Canvas V2: services
// ──────────────────────────────────────────────

ponder.on("NormiesCanvasV2:CanvasEnlarged", async ({ event, context }) => {
  const { tokenId, fromSize, toSize, cost, source } = event.args;
  const meta = eventMeta(event);
  await upsertCanvasState(context, tokenId, { gridSize: Number(toSize) }, meta);
  await context.db.insert(canvasSinkEvent).values({
    id: `${event.block.number}-${event.log.logIndex}`,
    tokenId,
    kind: "enlarge",
    fromSize: Number(fromSize),
    toSize: Number(toSize),
    cost,
    source: sourceName(Number(source)),
    by: event.transaction.from,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
  });
});

ponder.on("NormiesCanvasV2:BaseCleared", async ({ event, context }) => {
  const { tokenId, cost, source } = event.args;
  const meta = eventMeta(event);
  await upsertCanvasState(context, tokenId, { baseCleared: true }, meta);
  await context.db.insert(canvasSinkEvent).values({
    id: `${event.block.number}-${event.log.logIndex}`,
    tokenId,
    kind: "clearBase",
    fromSize: null,
    toSize: null,
    cost,
    source: sourceName(Number(source)),
    by: event.transaction.from,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
  });
});

// ──────────────────────────────────────────────
//  Market
// ──────────────────────────────────────────────

ponder.on("NormiesPixelMarket:ListingCreated", async ({ event, context }) => {
  const { listingId, seller, pricePerPixel, amount, partialFill, expiry } = event.args;
  const meta = eventMeta(event);
  await context.db.insert(marketListing).values({
    listingId,
    seller,
    pricePerPixel,
    amount: Number(amount),
    remaining: Number(amount),
    partialFill,
    expiry,
    status: "active",
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
    updatedBlockNumber: meta.blockNumber,
    updatedTimestamp: meta.timestamp,
    updatedTxHash: meta.txHash,
  });
  await patchMarketStats(context, (s) => ({ listings: s.listings + 1 }), meta);
});

ponder.on("NormiesPixelMarket:ListingFilled", async ({ event, context }) => {
  const { listingId, buyer, seller, amount, remaining, grossWei, feeWei } = event.args;
  const meta = eventMeta(event);
  const listing = await context.db.find(marketListing, { listingId });

  await context.db.update(marketListing, { listingId }).set({
    remaining: Number(remaining),
    status: Number(remaining) === 0 ? "filled" : "active",
    updatedBlockNumber: meta.blockNumber,
    updatedTimestamp: meta.timestamp,
    updatedTxHash: meta.txHash,
  });

  await context.db.insert(marketFill).values({
    id: `${event.block.number}-${event.log.logIndex}`,
    listingId,
    buyer,
    seller,
    amount: Number(amount),
    pricePerPixel: listing?.pricePerPixel ?? grossWei / BigInt(amount),
    grossWei,
    feeWei,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
    logIndex: Number(event.log.logIndex),
  });

  await patchMarketStats(
    context,
    (s) => ({
      volumeWei: s.volumeWei + grossWei,
      feesWei: s.feesWei + feeWei,
      pixelsTraded: s.pixelsTraded + BigInt(amount),
      fills: s.fills + 1,
    }),
    meta,
  );
});

ponder.on("NormiesPixelMarket:ListingCancelled", async ({ event, context }) => {
  const { listingId } = event.args;
  const meta = eventMeta(event);
  await context.db.update(marketListing, { listingId }).set({
    remaining: 0,
    status: "cancelled",
    updatedBlockNumber: meta.blockNumber,
    updatedTimestamp: meta.timestamp,
    updatedTxHash: meta.txHash,
  });
});

ponder.on("NormiesPixelMarket:FeesPaid", async ({ event, context }) => {
  const { treasuryWei, revenueShareWei } = event.args;
  await patchMarketStats(
    context,
    (s) => ({ feesCollectedWei: s.feesCollectedWei + treasuryWei + revenueShareWei }),
    eventMeta(event),
  );
});

ponder.on("NormiesPixelMarket:FeeConfigSet", async ({ event, context }) => {
  const { feeBps, revenueShareBps } = event.args;
  await patchMarketStats(
    context,
    () => ({ feeBps: Number(feeBps), revenueShareBps: Number(revenueShareBps) }),
    eventMeta(event),
  );
});

ponder.on("NormiesPixelMarket:PausedSet", async ({ event, context }) => {
  const { paused } = event.args;
  await patchMarketStats(context, () => ({ paused }), eventMeta(event));
});

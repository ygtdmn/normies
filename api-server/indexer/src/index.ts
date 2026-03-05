import { ponder } from "ponder:registry";
import {
  normieOwner,
  delegation,
  burnCommitment,
  burnedToken,
  pixelTransform,
} from "ponder:schema";
import { parseAbi } from "viem";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const commitPixelCountsABI = parseAbi([
  "function commitPixelCounts(uint256 commitId) view returns (uint256[])",
]);
const canvasStorageABI = parseAbi([
  "function canvasStorage() view returns (address)",
]);
const getTransformedImageDataABI = parseAbi([
  "function getTransformedImageData(uint256 tokenId) view returns (bytes)",
]);

// Lazily resolved canvas storage address (read once from contract)
let canvasStorageAddress: `0x${string}` | undefined;

// ──────────────────────────────────────────────
//  Normies: Transfer
// ──────────────────────────────────────────────

ponder.on("Normies:Transfer", async ({ event, context }) => {
  const { to, tokenId } = event.args;

  if (to === ZERO_ADDRESS) {
    await context.db.delete(normieOwner, { tokenId });

    // Track every burn for history (correlate with burn_commitment via txHash)
    await context.db
      .insert(burnedToken)
      .values({
        tokenId,
        txHash: event.transaction.hash,
        blockNumber: event.block.number,
        timestamp: event.block.timestamp,
      })
      .onConflictDoNothing();
  } else {
    await context.db
      .insert(normieOwner)
      .values({ tokenId, owner: to })
      .onConflictDoUpdate(() => ({ owner: to }));
  }
});

// ──────────────────────────────────────────────
//  NormiesCanvas: Delegation
// ──────────────────────────────────────────────

ponder.on("NormiesCanvas:DelegateSet", async ({ event, context }) => {
  const { tokenId, delegate } = event.args;

  await context.db
    .insert(delegation)
    .values({ tokenId, delegate })
    .onConflictDoUpdate(() => ({ delegate }));
});

ponder.on("NormiesCanvas:DelegateRevoked", async ({ event, context }) => {
  const { tokenId } = event.args;
  await context.db.delete(delegation, { tokenId });
});

// ──────────────────────────────────────────────
//  NormiesCanvas: Burns
// ──────────────────────────────────────────────

ponder.on("NormiesCanvas:BurnCommitted", async ({ event, context }) => {
  const { commitId, owner, receiverTokenId, tokenCount, transferredActionPoints } = event.args;

  // Read per-token pixel counts from on-chain commitment struct
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
    // Non-critical: pixel counts are also readable via contract view function
  }

  await context.db.insert(burnCommitment).values({
    commitId,
    owner,
    receiverTokenId,
    tokenCount: Number(tokenCount),
    transferredActionPoints,
    pixelCounts: pixelCountsJson,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
    revealed: false,
  });
});

ponder.on("NormiesCanvas:BurnRevealed", async ({ event, context }) => {
  const { commitId, totalActions, expired } = event.args;

  await context.db.update(burnCommitment, { commitId }).set({
    revealed: true,
    totalActions,
    expired,
    revealBlockNumber: event.block.number,
    revealTimestamp: event.block.timestamp,
    revealTxHash: event.transaction.hash,
  });
});

// ──────────────────────────────────────────────
//  NormiesCanvas: Pixel Transforms
// ──────────────────────────────────────────────

ponder.on("NormiesCanvas:PixelsTransformed", async ({ event, context }) => {
  const { transformer, tokenId, changeCount, newPixelCount } = event.args;

  // Read the transform bitmap from NormiesCanvasStorage
  let bitmap: `0x${string}` | undefined;
  try {
    if (!canvasStorageAddress) {
      canvasStorageAddress = await context.client.readContract({
        address: event.log.address,
        abi: canvasStorageABI,
        functionName: "canvasStorage",
      }) as `0x${string}`;
    }

    bitmap = await context.client.readContract({
      address: canvasStorageAddress,
      abi: getTransformedImageDataABI,
      functionName: "getTransformedImageData",
      args: [tokenId],
    }) as `0x${string}`;
  } catch {
    // Non-critical: bitmap may not be readable (e.g. storage contract upgraded)
  }

  await context.db.insert(pixelTransform).values({
    id: `${event.block.number}-${event.log.logIndex}`,
    tokenId,
    transformer,
    changeCount: Number(changeCount),
    newPixelCount: Number(newPixelCount),
    transformBitmap: bitmap ?? null,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
  });
});

import { ponder } from "ponder:registry";
import type { Context } from "ponder:registry";
import {
  normieOwner,
  delegation,
  tokenData,
  canvasTokenState,
  burnCommitment,
  burnedToken,
  pixelTransform,
  agentBinding,
} from "ponder:schema";
import { bytesToHex, encodePacked, hexToBytes, keccak256, parseAbi, toBytes } from "viem";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const REVEAL_PHRASE =
  "normies-ftw-lividly-pumice-consoling-equator-makeover-scone-speculate-dreamy-murky-zips-unplanted-verbalize";
const EXPECTED_REVEAL_HASH = "0xe733b398326d00945c58c635ae2c06a04aa9da7edc2a12659a91877410970a9f";
const REVEAL_HASH = keccak256(toBytes(REVEAL_PHRASE));
const REVEAL_HASH_BYTES = hexToBytes(REVEAL_HASH);

if (REVEAL_HASH !== EXPECTED_REVEAL_HASH) {
  throw new Error("Hardcoded reveal phrase does not match deployed reveal hash");
}

const commitPixelCountsABI = parseAbi([
  "function commitPixelCounts(uint256 commitId) view returns (uint256[])",
]);
const canvasStorageABI = parseAbi([
  "function canvasStorage() view returns (address)",
]);
const getTransformedImageDataABI = parseAbi([
  "function getTransformedImageData(uint256 tokenId) view returns (bytes)",
]);

type IndexingContext = Context;
type EventMeta = {
  blockNumber: bigint;
  timestamp: bigint;
  txHash: `0x${string}`;
};

function eventMeta(event: { block: { number: bigint; timestamp: bigint }; transaction: { hash: `0x${string}` } }): EventMeta {
  return {
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
  };
}

async function readCanvasStorageAddress(context: IndexingContext, canvasAddress: `0x${string}`): Promise<`0x${string}`> {
  return context.client.readContract({
    address: canvasAddress,
    abi: canvasStorageABI,
    functionName: "canvasStorage",
    args: [],
  }) as Promise<`0x${string}`>;
}

async function upsertDefaultCanvasState(
  context: IndexingContext,
  tokenId: bigint,
  meta: EventMeta,
): Promise<void> {
  await context.db
    .insert(canvasTokenState)
    .values({
      tokenId,
      actionPoints: 0n,
      customized: false,
      delegate: ZERO_ADDRESS,
      delegateSetBy: ZERO_ADDRESS,
      latestTransformBitmap: null,
      blockNumber: meta.blockNumber,
      timestamp: meta.timestamp,
      txHash: meta.txHash,
    })
    .onConflictDoNothing();
}

function decryptImageData(encryptedImageData: `0x${string}`): `0x${string}` {
  const data = Uint8Array.from(hexToBytes(encryptedImageData));
  let key = new Uint8Array(32);

  for (let i = 0; i < data.length; i++) {
    if ((i & 31) === 0) {
      key = Uint8Array.from(hexToBytes(
        keccak256(
          encodePacked(
            ["bytes32", "uint256"],
            [REVEAL_HASH, BigInt(Math.floor(i / 32))],
          ),
        ),
      ));
    }
    data[i] = data[i]! ^ key[i & 31]!;
  }

  return bytesToHex(data);
}

function decryptTraitsHex(encryptedTraits: `0x${string}`): `0x${string}` {
  const traits = Uint8Array.from(hexToBytes(encryptedTraits));
  for (let i = 0; i < traits.length; i++) {
    traits[i] = traits[i]! ^ REVEAL_HASH_BYTES[i]!;
  }
  return bytesToHex(traits);
}

async function upsertTokenDataFromMint(
  context: IndexingContext,
  tokenId: bigint,
  encryptedImageData: `0x${string}`,
  encryptedTraits: `0x${string}`,
  meta: EventMeta,
): Promise<void> {
  const rawImageData = decryptImageData(encryptedImageData);
  const traitsHex = decryptTraitsHex(encryptedTraits);

  await context.db
    .insert(tokenData)
    .values({
      tokenId,
      rawImageData,
      traitsHex,
      blockNumber: meta.blockNumber,
      timestamp: meta.timestamp,
      txHash: meta.txHash,
    })
    .onConflictDoUpdate({
      rawImageData,
      traitsHex,
      blockNumber: meta.blockNumber,
      timestamp: meta.timestamp,
      txHash: meta.txHash,
    });
}

async function upsertCanvasState(
  context: IndexingContext,
  tokenId: bigint,
  values: {
    actionPoints?: bigint;
    customized?: boolean;
    delegate?: `0x${string}`;
    delegateSetBy?: `0x${string}`;
    latestTransformBitmap?: `0x${string}` | null;
  },
  meta: EventMeta,
): Promise<void> {
  const existing = await context.db.find(canvasTokenState, { tokenId });
  const next = {
    tokenId,
    actionPoints: values.actionPoints ?? existing?.actionPoints ?? 0n,
    customized: values.customized ?? existing?.customized ?? false,
    delegate: values.delegate ?? existing?.delegate ?? ZERO_ADDRESS,
    delegateSetBy: values.delegateSetBy ?? existing?.delegateSetBy ?? ZERO_ADDRESS,
    latestTransformBitmap: values.latestTransformBitmap !== undefined
      ? values.latestTransformBitmap
      : existing?.latestTransformBitmap ?? null,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
  };

  await context.db
    .insert(canvasTokenState)
    .values(next)
    .onConflictDoUpdate({
      actionPoints: next.actionPoints,
      customized: next.customized,
      delegate: next.delegate,
      delegateSetBy: next.delegateSetBy,
      latestTransformBitmap: next.latestTransformBitmap,
      blockNumber: next.blockNumber,
      timestamp: next.timestamp,
      txHash: next.txHash,
    });
}

// ──────────────────────────────────────────────
//  Normies: Transfer
// ──────────────────────────────────────────────

ponder.on("Normies:Transfer", async ({ event, context }) => {
  const { to, tokenId } = event.args;

  if (to === ZERO_ADDRESS) {
    await context.db.delete(normieOwner, { tokenId });
    await context.db.delete(delegation, { tokenId });
    await upsertCanvasState(
      context,
      tokenId,
      {
        actionPoints: 0n,
        customized: false,
        delegate: ZERO_ADDRESS,
        delegateSetBy: ZERO_ADDRESS,
        latestTransformBitmap: null,
      },
      eventMeta(event),
    );

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
//  NormiesMinterV2: Mint
// ──────────────────────────────────────────────

ponder.on("NormiesMinterV2:Mint", async ({ event, context }) => {
  const { tokenId, imageData, traits } = event.args;
  const meta = eventMeta(event);

  await upsertTokenDataFromMint(context, tokenId, imageData, traits, meta);
  await upsertDefaultCanvasState(context, tokenId, meta);
});

// ──────────────────────────────────────────────
//  NormiesCanvas: Delegation
// ──────────────────────────────────────────────

ponder.on("NormiesCanvas:DelegateSet", async ({ event, context }) => {
  const { tokenId, delegate } = event.args;
  const meta = eventMeta(event);
  const delegateSetBy = event.transaction.from;

  await context.db
    .insert(delegation)
    .values({ tokenId, delegate })
    .onConflictDoUpdate(() => ({ delegate }));
  await upsertCanvasState(context, tokenId, { delegate, delegateSetBy }, meta);
});

ponder.on("NormiesCanvas:DelegateRevoked", async ({ event, context }) => {
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
  const { commitId, receiverTokenId, totalActions, expired } = event.args;
  const meta = eventMeta(event);

  await context.db.update(burnCommitment, { commitId }).set({
    revealed: true,
    totalActions,
    expired,
    revealBlockNumber: event.block.number,
    revealTimestamp: event.block.timestamp,
    revealTxHash: event.transaction.hash,
  });

  const existing = await context.db.find(canvasTokenState, { tokenId: receiverTokenId });
  await upsertCanvasState(
    context,
    receiverTokenId,
    { actionPoints: (existing?.actionPoints ?? 0n) + totalActions },
    meta,
  );
});

// ──────────────────────────────────────────────
//  NormiesCanvas: Pixel Transforms
// ──────────────────────────────────────────────

ponder.on("NormiesCanvas:PixelsTransformed", async ({ event, context }) => {
  const { transformer, tokenId, changeCount, newPixelCount } = event.args;

  const storageAddress = await readCanvasStorageAddress(context, event.log.address);
  const bitmap = await context.client.readContract({
    address: storageAddress,
    abi: getTransformedImageDataABI,
    functionName: "getTransformedImageData",
    args: [tokenId],
  }) as `0x${string}`;

  await context.db.insert(pixelTransform).values({
    id: `${event.block.number}-${event.log.logIndex}`,
    tokenId,
    transformer,
    changeCount: Number(changeCount),
    newPixelCount: Number(newPixelCount),
    transformBitmap: bitmap,
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
  });
  await upsertCanvasState(
    context,
    tokenId,
    { customized: true, latestTransformBitmap: bitmap },
    eventMeta(event),
  );
});

// ──────────────────────────────────────────────
//  Adapter8004: AgentBound
//
//  Idempotent insert keyed on (standard, tokenContract, tokenId). The
//  adapter contract guards against re-registration, so we don't expect
//  collisions in practice — `onConflictDoNothing` is just belt-and-suspenders.
// ──────────────────────────────────────────────

ponder.on("Adapter8004:AgentBound", async ({ event, context }) => {
  const { agentId, standard, tokenContract, tokenId, registeredBy } = event.args;
  const id = `${standard}:${tokenContract.toLowerCase()}:${tokenId}`;

  await context.db
    .insert(agentBinding)
    .values({
      id,
      agentId,
      standard: Number(standard),
      tokenContract,
      tokenId,
      registeredBy,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    })
    .onConflictDoNothing();
});

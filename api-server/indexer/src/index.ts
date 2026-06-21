import { ponder } from "ponder:registry";
import type { Context } from "ponder:registry";
import {
  normieOwner,
  normieTransfer,
  delegation,
  tokenData,
  canvasTokenState,
  burnCommitment,
  burnedToken,
  pixelTransform,
  agentBinding,
  zombiePoolItem,
  zombieTokenState,
  zombieCommitment,
  zombieConfig,
  legendaryCanvasTrait,
  legendaryCanvasTraitEvent,
} from "ponder:schema";
import { bytesToHex, encodePacked, hexToBytes, hexToString, keccak256, parseAbi, toBytes } from "viem";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ZOMBIE_CONFIG_ID = "global";
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
const zombieStorageABI = parseAbi([
  "function getPoolBitmap(uint256 poolIndex) view returns (bytes)",
  "function getPoolAttributes(uint256 poolIndex) view returns (bytes)",
  "function poolSize() view returns (uint256)",
  "function isPoolSealed() view returns (bool)",
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

function zombieStorageAddress(): `0x${string}` {
  const value = process.env.PONDER_ZOMBIE_STORAGE_ADDRESS;
  if (!value) throw new Error("PONDER_ZOMBIE_STORAGE_ADDRESS must be configured");
  return value as `0x${string}`;
}

async function readZombiePoolItem(
  context: IndexingContext,
  storageAddress: `0x${string}`,
  poolIndex: bigint,
): Promise<{ bitmap: `0x${string}`; attributesJson: string }> {
  const [bitmap, attributesHex] = await Promise.all([
    context.client.readContract({
      address: storageAddress,
      abi: zombieStorageABI,
      functionName: "getPoolBitmap",
      args: [poolIndex],
    }) as Promise<`0x${string}`>,
    context.client.readContract({
      address: storageAddress,
      abi: zombieStorageABI,
      functionName: "getPoolAttributes",
      args: [poolIndex],
    }) as Promise<`0x${string}`>,
  ]);

  return { bitmap, attributesJson: hexToString(attributesHex) };
}

async function readZombiePoolSize(
  context: IndexingContext,
  storageAddress: `0x${string}`,
): Promise<number> {
  const value = await context.client.readContract({
    address: storageAddress,
    abi: zombieStorageABI,
    functionName: "poolSize",
    args: [],
  }) as bigint;
  return Number(value);
}

async function getStoredZombiePoolItem(
  context: IndexingContext,
  poolIndex: bigint,
  meta: EventMeta,
): Promise<{ bitmap: `0x${string}`; attributesJson: string }> {
  const existing = await context.db.find(zombiePoolItem, { poolIndex });
  if (existing) {
    return { bitmap: existing.bitmap, attributesJson: existing.attributesJson };
  }

  const item = await readZombiePoolItem(context, zombieStorageAddress(), poolIndex);
  await context.db
    .insert(zombiePoolItem)
    .values({
      poolIndex,
      bitmap: item.bitmap,
      attributesJson: item.attributesJson,
      bitmapPointer: null,
      attributesPointer: null,
      blockNumber: meta.blockNumber,
      timestamp: meta.timestamp,
      txHash: meta.txHash,
    })
    .onConflictDoUpdate({
      bitmap: item.bitmap,
      attributesJson: item.attributesJson,
      blockNumber: meta.blockNumber,
      timestamp: meta.timestamp,
      txHash: meta.txHash,
    });
  return item;
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

async function upsertZombieTokenState(
  context: IndexingContext,
  tokenId: bigint,
  values: {
    isZombie?: boolean;
    poolIndex?: bigint | null;
    bitmap?: `0x${string}` | null;
    attributesJson?: string | null;
    qualifyingWallet?: `0x${string}` | null;
    commitId?: bigint | null;
  },
  meta: EventMeta,
): Promise<void> {
  const existing = await context.db.find(zombieTokenState, { tokenId });
  const next = {
    tokenId,
    isZombie: values.isZombie ?? existing?.isZombie ?? false,
    poolIndex: values.poolIndex !== undefined ? values.poolIndex : existing?.poolIndex ?? null,
    bitmap: values.bitmap !== undefined ? values.bitmap : existing?.bitmap ?? null,
    attributesJson: values.attributesJson !== undefined ? values.attributesJson : existing?.attributesJson ?? null,
    qualifyingWallet: values.qualifyingWallet !== undefined
      ? values.qualifyingWallet
      : existing?.qualifyingWallet ?? null,
    commitId: values.commitId !== undefined ? values.commitId : existing?.commitId ?? null,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
  };

  await context.db
    .insert(zombieTokenState)
    .values(next)
    .onConflictDoUpdate({
      isZombie: next.isZombie,
      poolIndex: next.poolIndex,
      bitmap: next.bitmap,
      attributesJson: next.attributesJson,
      qualifyingWallet: next.qualifyingWallet,
      commitId: next.commitId,
      blockNumber: next.blockNumber,
      timestamp: next.timestamp,
      txHash: next.txHash,
    });
}

async function upsertZombieConfig(
  context: IndexingContext,
  values: {
    paused?: boolean;
    merkleRoot?: `0x${string}` | null;
    seedBlock?: bigint | null;
    seed?: `0x${string}` | null;
    seedLocked?: boolean;
    poolSize?: number;
    poolSealed?: boolean;
  },
  meta: EventMeta,
): Promise<void> {
  const existing = await context.db.find(zombieConfig, { id: ZOMBIE_CONFIG_ID });
  const next = {
    id: ZOMBIE_CONFIG_ID,
    paused: values.paused ?? existing?.paused ?? true,
    merkleRoot: values.merkleRoot !== undefined ? values.merkleRoot : existing?.merkleRoot ?? null,
    seedBlock: values.seedBlock !== undefined ? values.seedBlock : existing?.seedBlock ?? null,
    seed: values.seed !== undefined ? values.seed : existing?.seed ?? null,
    seedLocked: values.seedLocked ?? existing?.seedLocked ?? false,
    poolSize: values.poolSize ?? existing?.poolSize ?? 0,
    poolSealed: values.poolSealed ?? existing?.poolSealed ?? false,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
  };

  await context.db
    .insert(zombieConfig)
    .values(next)
    .onConflictDoUpdate({
      paused: next.paused,
      merkleRoot: next.merkleRoot,
      seedBlock: next.seedBlock,
      seed: next.seed,
      seedLocked: next.seedLocked,
      poolSize: next.poolSize,
      poolSealed: next.poolSealed,
      blockNumber: next.blockNumber,
      timestamp: next.timestamp,
      txHash: next.txHash,
    });
}

// ──────────────────────────────────────────────
//  Normies: Transfer
// ──────────────────────────────────────────────

ponder.on("Normies:Transfer", async ({ event, context }) => {
  const { from, to, tokenId } = event.args;

  await context.db
    .insert(normieTransfer)
    .values({
      id: `${event.block.number}-${event.log.logIndex}`,
      tokenId,
      from,
      to,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
      logIndex: Number(event.log.logIndex),
    })
    .onConflictDoNothing();

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
//  NormiesZombieStorage: Pool Assets & Token State
// ──────────────────────────────────────────────

ponder.on("NormiesZombieStorage:ZombieAdded", async ({ event, context }) => {
  const { poolIndex, bitmapPointer, attributesPointer } = event.args;
  const meta = eventMeta(event);
  const item = await readZombiePoolItem(context, event.log.address, poolIndex);
  const poolSize = await readZombiePoolSize(context, event.log.address);

  await context.db
    .insert(zombiePoolItem)
    .values({
      poolIndex,
      bitmap: item.bitmap,
      attributesJson: item.attributesJson,
      bitmapPointer,
      attributesPointer,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    })
    .onConflictDoUpdate({
      bitmap: item.bitmap,
      attributesJson: item.attributesJson,
      bitmapPointer,
      attributesPointer,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    });

  await upsertZombieConfig(context, { poolSize }, meta);
});

ponder.on("NormiesZombieStorage:PoolSealed", async ({ event, context }) => {
  const { poolSize } = event.args;
  await upsertZombieConfig(
    context,
    { poolSize: Number(poolSize), poolSealed: true },
    eventMeta(event),
  );
});

ponder.on("NormiesZombieStorage:ZombieSet", async ({ event, context }) => {
  const { tokenId, poolIndex } = event.args;
  const meta = eventMeta(event);
  const item = await getStoredZombiePoolItem(context, poolIndex, meta);

  await upsertZombieTokenState(
    context,
    tokenId,
    {
      isZombie: true,
      poolIndex,
      bitmap: item.bitmap,
      attributesJson: item.attributesJson,
    },
    meta,
  );
});

// ──────────────────────────────────────────────
//  NormiesZombie: Config & Conversions
// ──────────────────────────────────────────────

ponder.on("NormiesZombie:MerkleRootSet", async ({ event, context }) => {
  await upsertZombieConfig(
    context,
    { merkleRoot: event.args.merkleRoot },
    eventMeta(event),
  );
});

ponder.on("NormiesZombie:SeedBlockSet", async ({ event, context }) => {
  await upsertZombieConfig(
    context,
    { seedBlock: event.args.seedBlock },
    eventMeta(event),
  );
});

ponder.on("NormiesZombie:SeedLocked", async ({ event, context }) => {
  const { seed, poolSize } = event.args;
  await upsertZombieConfig(
    context,
    {
      seed,
      seedLocked: true,
      poolSize: Number(poolSize),
      poolSealed: true,
    },
    eventMeta(event),
  );
});

ponder.on("NormiesZombie:PausedSet", async ({ event, context }) => {
  await upsertZombieConfig(
    context,
    { paused: event.args.paused },
    eventMeta(event),
  );
});

ponder.on("NormiesZombie:ZombieConvertCommitted", async ({ event, context }) => {
  const { commitId, qualifyingWallet, tokenId, index, committer, committedOwner } = event.args;

  await context.db
    .insert(zombieCommitment)
    .values({
      commitId,
      qualifyingWallet,
      tokenId,
      index,
      committer,
      committedOwner,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
      revealed: false,
      cancelled: false,
      poolIndex: null,
      revealBlockNumber: null,
      revealTimestamp: null,
      revealTxHash: null,
      cancelBlockNumber: null,
      cancelTimestamp: null,
      cancelTxHash: null,
    })
    .onConflictDoUpdate({
      qualifyingWallet,
      tokenId,
      index,
      committer,
      committedOwner,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
      revealed: false,
      cancelled: false,
      poolIndex: null,
      revealBlockNumber: null,
      revealTimestamp: null,
      revealTxHash: null,
      cancelBlockNumber: null,
      cancelTimestamp: null,
      cancelTxHash: null,
    });
});

ponder.on("NormiesZombie:ZombieConverted", async ({ event, context }) => {
  const { commitId, tokenId, qualifyingWallet, poolIndex } = event.args;
  const meta = eventMeta(event);
  const item = await getStoredZombiePoolItem(context, poolIndex, meta);

  const commitment = await context.db.find(zombieCommitment, { commitId });
  if (commitment) {
    await context.db.update(zombieCommitment, { commitId }).set({
      revealed: true,
      cancelled: false,
      poolIndex,
      revealBlockNumber: event.block.number,
      revealTimestamp: event.block.timestamp,
      revealTxHash: event.transaction.hash,
    });
  }

  await upsertZombieTokenState(
    context,
    tokenId,
    {
      isZombie: true,
      poolIndex,
      bitmap: item.bitmap,
      attributesJson: item.attributesJson,
      qualifyingWallet,
      commitId,
    },
    meta,
  );
});

ponder.on("NormiesZombie:ZombieCommitCancelled", async ({ event, context }) => {
  const { commitId } = event.args;
  const commitment = await context.db.find(zombieCommitment, { commitId });
  if (!commitment) return;

  await context.db.update(zombieCommitment, { commitId }).set({
    revealed: false,
    cancelled: true,
    cancelBlockNumber: event.block.number,
    cancelTimestamp: event.block.timestamp,
    cancelTxHash: event.transaction.hash,
  });
});

// ──────────────────────────────────────────────
//  NormiesLegendaryCanvas: Optional Artist Trait
// ──────────────────────────────────────────────

ponder.on("NormiesLegendaryCanvas:LegendaryCanvasSet", async ({ event, context }) => {
  const { tokenId, artistName, operator } = event.args;

  await context.db
    .insert(legendaryCanvasTraitEvent)
    .values({
      id: `${event.block.number}-${event.log.logIndex}`,
      tokenId,
      isLegendary: true,
      artistName,
      operator,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
      logIndex: Number(event.log.logIndex),
    })
    .onConflictDoNothing();

  await context.db
    .insert(legendaryCanvasTrait)
    .values({
      tokenId,
      isLegendary: true,
      artistName,
      operator,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    })
    .onConflictDoUpdate({
      isLegendary: true,
      artistName,
      operator,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    });
});

ponder.on("NormiesLegendaryCanvas:LegendaryCanvasCleared", async ({ event, context }) => {
  const { tokenId, operator } = event.args;

  await context.db
    .insert(legendaryCanvasTraitEvent)
    .values({
      id: `${event.block.number}-${event.log.logIndex}`,
      tokenId,
      isLegendary: false,
      artistName: null,
      operator,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
      logIndex: Number(event.log.logIndex),
    })
    .onConflictDoNothing();

  await context.db
    .insert(legendaryCanvasTrait)
    .values({
      tokenId,
      isLegendary: false,
      artistName: null,
      operator,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    })
    .onConflictDoUpdate({
      isLegendary: false,
      artistName: null,
      operator,
      blockNumber: event.block.number,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    });
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

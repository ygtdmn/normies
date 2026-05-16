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
import { createPublicClient, http, parseAbi } from "viem";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
const BACKFILL_CHUNK_SIZE = Number(process.env.PONDER_BACKFILL_CHUNK_SIZE ?? 100);
const STORAGE_ADDRESS = requiredEnv("PONDER_STORAGE_ADDRESS") as `0x${string}`;
const NORMIES_ADDRESS = requiredEnv("PONDER_NORMIES_ADDRESS") as `0x${string}`;
const CANVAS_ADDRESS = requiredEnv("PONDER_CANVAS_ADDRESS") as `0x${string}`;

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} must be configured`);
  return value;
}

const commitPixelCountsABI = parseAbi([
  "function commitPixelCounts(uint256 commitId) view returns (uint256[])",
]);
const normiesABI = parseAbi([
  "function maxSupply() view returns (uint256)",
]);
const storageABI = parseAbi([
  "function isTokenDataSet(uint256 tokenId) view returns (bool)",
  "function getTokenRawImageData(uint256 tokenId) view returns (bytes)",
  "function getTokenTraits(uint256 tokenId) view returns (bytes8)",
]);
const canvasABI = parseAbi([
  "function actionPoints(uint256 tokenId) view returns (uint256)",
  "function delegates(uint256 tokenId) view returns (address)",
  "function delegateSetBy(uint256 tokenId) view returns (address)",
]);
const canvasStorageABI = parseAbi([
  "function canvasStorage() view returns (address)",
  "function isTransformed(uint256 tokenId) view returns (bool)",
]);
const getTransformedImageDataABI = parseAbi([
  "function getTransformedImageData(uint256 tokenId) view returns (bytes)",
]);

// Latest canvas storage address used by the current-state startup backfill.
let canvasStorageAddress: `0x${string}` | undefined;

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

function backfillMeta(blockNumber: bigint, timestamp: bigint): EventMeta {
  return { blockNumber, timestamp, txHash: ZERO_HASH };
}

async function readCanvasStorageAddress(context: IndexingContext, canvasAddress: `0x${string}`): Promise<`0x${string}`> {
  return context.client.readContract({
    address: canvasAddress,
    abi: canvasStorageABI,
    functionName: "canvasStorage",
    args: [],
  }) as Promise<`0x${string}`>;
}

async function hasNewerCanvasState(
  context: IndexingContext,
  tokenId: bigint,
  blockNumber: bigint,
): Promise<boolean> {
  const row = await context.db.find(canvasTokenState, { tokenId });
  return !!row && row.blockNumber > blockNumber;
}

async function hasNewerTokenData(
  context: IndexingContext,
  tokenId: bigint,
  blockNumber: bigint,
): Promise<boolean> {
  const row = await context.db.find(tokenData, { tokenId });
  return !!row && row.blockNumber > blockNumber;
}

async function upsertDefaultCanvasState(
  context: IndexingContext,
  tokenId: bigint,
  meta: EventMeta,
): Promise<void> {
  if (await hasNewerCanvasState(context, tokenId, meta.blockNumber)) return;
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

async function upsertTokenDataFromStorage(
  context: IndexingContext,
  tokenId: bigint,
  meta: EventMeta,
): Promise<void> {
  if (await hasNewerTokenData(context, tokenId, meta.blockNumber)) return;

  const [rawImageData, traitsHex] = await Promise.all([
    context.client.readContract({
      address: STORAGE_ADDRESS,
      abi: storageABI,
      functionName: "getTokenRawImageData",
      args: [tokenId],
    }) as Promise<`0x${string}`>,
    context.client.readContract({
      address: STORAGE_ADDRESS,
      abi: storageABI,
      functionName: "getTokenTraits",
      args: [tokenId],
    }) as Promise<`0x${string}`>,
  ]);

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
  if (await hasNewerCanvasState(context, tokenId, meta.blockNumber)) return;
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

function chunk<T>(values: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < values.length; i += size) {
    chunks.push(values.slice(i, i + size));
  }
  return chunks;
}

function multicallResult<T>(value: unknown): T {
  if (
    typeof value === "object" &&
    value !== null &&
    "status" in value &&
    value.status === "success" &&
    "result" in value
  ) {
    return (value as { result: T }).result;
  }
  throw new Error("Required backfill contract read failed");
}

async function backfillTokenAndCanvasState(context: IndexingContext): Promise<void> {
  if (process.env.PONDER_BACKFILL_ON_START === "false") return;

  const latestClient = createPublicClient({ transport: http(requiredEnv("PONDER_RPC_URL")) });
  const latestBlockNumber = await latestClient.getBlockNumber();
  const latestBlock = await latestClient.getBlock({ blockNumber: latestBlockNumber });
  const meta = backfillMeta(latestBlockNumber, latestBlock.timestamp);

  const maxSupply = Number(await context.client.readContract({
    address: NORMIES_ADDRESS,
    abi: normiesABI,
    functionName: "maxSupply",
    args: [],
    cache: "immutable",
  }));

  canvasStorageAddress = await context.client.readContract({
    address: CANVAS_ADDRESS,
    abi: canvasStorageABI,
    functionName: "canvasStorage",
    args: [],
    cache: "immutable",
  }) as `0x${string}`;

  const ids = Array.from({ length: maxSupply }, (_, tokenId) => BigInt(tokenId));
  for (const idChunk of chunk(ids, BACKFILL_CHUNK_SIZE)) {
    const isSetResults = await context.client.multicall({
      allowFailure: true,
      cache: "immutable",
      contracts: idChunk.map((tokenId) => ({
        address: STORAGE_ADDRESS,
        abi: storageABI,
        functionName: "isTokenDataSet",
        args: [tokenId],
      })),
    });
    const setIds = idChunk.filter((_, index) => multicallResult<boolean>(isSetResults[index]));
    if (setIds.length === 0) continue;

    const tokenReads = await context.client.multicall({
      allowFailure: true,
      cache: "immutable",
      contracts: setIds.flatMap((tokenId) => [
        {
          address: STORAGE_ADDRESS,
          abi: storageABI,
          functionName: "getTokenRawImageData",
          args: [tokenId],
        },
        {
          address: STORAGE_ADDRESS,
          abi: storageABI,
          functionName: "getTokenTraits",
          args: [tokenId],
        },
      ]),
    });

    const canvasReads = await context.client.multicall({
      allowFailure: true,
      cache: "immutable",
      contracts: setIds.flatMap((tokenId) => [
        {
          address: CANVAS_ADDRESS,
          abi: canvasABI,
          functionName: "actionPoints",
          args: [tokenId],
        },
        {
          address: CANVAS_ADDRESS,
          abi: canvasABI,
          functionName: "delegates",
          args: [tokenId],
        },
        {
          address: CANVAS_ADDRESS,
          abi: canvasABI,
          functionName: "delegateSetBy",
          args: [tokenId],
        },
        {
          address: canvasStorageAddress!,
          abi: canvasStorageABI,
          functionName: "isTransformed",
          args: [tokenId],
        },
      ]),
    });

    const transformedIds = setIds.filter((_, index) => {
      const base = index * 4;
      return multicallResult<boolean>(canvasReads[base + 3]);
    });
    const transformReads = transformedIds.length > 0
      ? await context.client.multicall({
          allowFailure: true,
          cache: "immutable",
          contracts: transformedIds.map((tokenId) => ({
            address: canvasStorageAddress!,
            abi: getTransformedImageDataABI,
            functionName: "getTransformedImageData",
            args: [tokenId],
          })),
        })
      : [];
    const transformBitmapByTokenId = new Map<bigint, `0x${string}`>();
    transformedIds.forEach((tokenId, index) => {
      transformBitmapByTokenId.set(tokenId, multicallResult<`0x${string}`>(transformReads[index]));
    });

    for (const [index, tokenId] of setIds.entries()) {
      const tokenBase = index * 2;
      const canvasBase = index * 4;
      const rawImageData = multicallResult<`0x${string}`>(tokenReads[tokenBase]);
      const traitsHex = multicallResult<`0x${string}`>(tokenReads[tokenBase + 1]);
      const actionPoints = multicallResult<bigint>(canvasReads[canvasBase]);
      const delegate = multicallResult<`0x${string}`>(canvasReads[canvasBase + 1]);
      const delegateSetBy = multicallResult<`0x${string}`>(canvasReads[canvasBase + 2]);
      const customized = multicallResult<boolean>(canvasReads[canvasBase + 3]);
      const latestTransformBitmap = customized ? transformBitmapByTokenId.get(tokenId) : null;
      if (customized && !latestTransformBitmap) {
        throw new Error(`Missing transform bitmap while backfilling token ${tokenId}`);
      }

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

      await upsertCanvasState(
        context,
        tokenId,
        {
          actionPoints,
          customized,
          delegate,
          delegateSetBy,
          latestTransformBitmap,
        },
        meta,
      );
      if (delegate === ZERO_ADDRESS) {
        await context.db.delete(delegation, { tokenId });
      } else {
        await context.db
          .insert(delegation)
          .values({ tokenId, delegate })
          .onConflictDoUpdate({ delegate });
      }
    }
  }
}

// ──────────────────────────────────────────────
//  Startup backfill
// ──────────────────────────────────────────────

ponder.on("Normies:setup", async ({ context }) => {
  await backfillTokenAndCanvasState(context);
});

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
//  NormiesMinter: Mint
// ──────────────────────────────────────────────

ponder.on("NormiesMinter:Mint", async ({ event, context }) => {
  const { tokenId } = event.args;
  const meta = eventMeta(event);

  await upsertTokenDataFromStorage(context, tokenId, meta);
  await upsertDefaultCanvasState(context, tokenId, meta);
});

// ──────────────────────────────────────────────
//  NormiesCanvas: Delegation
// ──────────────────────────────────────────────

ponder.on("NormiesCanvas:DelegateSet", async ({ event, context }) => {
  const { tokenId, delegate } = event.args;
  const meta = eventMeta(event);
  const delegateSetBy = await context.client.readContract({
    address: event.log.address,
    abi: canvasABI,
    functionName: "delegateSetBy",
    args: [tokenId],
  }) as `0x${string}`;

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
  if (!existing || existing.blockNumber <= event.block.number) {
    await upsertCanvasState(
      context,
      receiverTokenId,
      { actionPoints: (existing?.actionPoints ?? 0n) + totalActions },
      meta,
    );
  }
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

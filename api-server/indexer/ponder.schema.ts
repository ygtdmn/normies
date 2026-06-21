import { onchainTable, index } from "ponder";

export const normieOwner = onchainTable(
  "normie_owner",
  (t) => ({
    tokenId: t.bigint().primaryKey(),
    owner: t.hex().notNull(),
  }),
  (table) => ({
    ownerIdx: index().on(table.owner),
  }),
);

export const normieTransfer = onchainTable(
  "normie_transfer",
  (t) => ({
    id: t.text().primaryKey(),
    tokenId: t.bigint().notNull(),
    from: t.hex().notNull(),
    to: t.hex().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    tokenBlockIdx: index().on(table.tokenId, table.blockNumber),
    blockIdx: index().on(table.blockNumber),
    toIdx: index().on(table.to),
  }),
);

export const delegation = onchainTable(
  "delegation",
  (t) => ({
    tokenId: t.bigint().primaryKey(),
    delegate: t.hex().notNull(),
  }),
  (table) => ({
    delegateIdx: index().on(table.delegate),
  }),
);

export const tokenData = onchainTable(
  "token_data",
  (t) => ({
    tokenId: t.bigint().primaryKey(),
    rawImageData: t.hex().notNull(),
    traitsHex: t.hex().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
);

export const canvasTokenState = onchainTable(
  "canvas_token_state",
  (t) => ({
    tokenId: t.bigint().primaryKey(),
    actionPoints: t.bigint().notNull().default(0n),
    customized: t.boolean().notNull().default(false),
    delegate: t.hex().notNull(),
    delegateSetBy: t.hex().notNull(),
    latestTransformBitmap: t.hex(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
);

export const burnCommitment = onchainTable(
  "burn_commitment",
  (t) => ({
    commitId: t.bigint().primaryKey(),
    owner: t.hex().notNull(),
    receiverTokenId: t.bigint().notNull(),
    tokenCount: t.integer().notNull(),
    transferredActionPoints: t.bigint().notNull(),
    pixelCounts: t.text(), // JSON array from commitPixelCounts()
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    revealed: t.boolean().notNull().default(false),
    totalActions: t.bigint(),
    expired: t.boolean(),
    revealBlockNumber: t.bigint(),
    revealTimestamp: t.bigint(),
    revealTxHash: t.hex(),
  }),
  (table) => ({
    ownerIdx: index().on(table.owner),
    receiverIdx: index().on(table.receiverTokenId),
    txHashIdx: index().on(table.txHash),
  }),
);

export const burnedToken = onchainTable(
  "burned_token",
  (t) => ({
    tokenId: t.bigint().primaryKey(),
    txHash: t.hex().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
  (table) => ({
    txHashIdx: index().on(table.txHash),
  }),
);

export const pixelTransform = onchainTable(
  "pixel_transform",
  (t) => ({
    id: t.text().primaryKey(),
    tokenId: t.bigint().notNull(),
    transformer: t.hex().notNull(),
    changeCount: t.integer().notNull(),
    newPixelCount: t.integer().notNull(),
    transformBitmap: t.hex(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    tokenIdx: index().on(table.tokenId),
    transformerIdx: index().on(table.transformer),
    timestampIdx: index().on(table.timestamp),
  }),
);

// ──────────────────────────────────────────────
//  NormiesZombie
// ──────────────────────────────────────────────

export const zombiePoolItem = onchainTable(
  "zombie_pool_item",
  (t) => ({
    poolIndex: t.bigint().primaryKey(),
    bitmap: t.hex().notNull(),
    attributesJson: t.text().notNull(),
    bitmapPointer: t.hex(),
    attributesPointer: t.hex(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
);

export const zombieTokenState = onchainTable(
  "zombie_token_state",
  (t) => ({
    tokenId: t.bigint().primaryKey(),
    isZombie: t.boolean().notNull().default(false),
    poolIndex: t.bigint(),
    bitmap: t.hex(),
    attributesJson: t.text(),
    qualifyingWallet: t.hex(),
    commitId: t.bigint(),
    blockNumber: t.bigint(),
    timestamp: t.bigint(),
    txHash: t.hex(),
  }),
  (table) => ({
    poolIdx: index().on(table.poolIndex),
    walletIdx: index().on(table.qualifyingWallet),
    commitIdx: index().on(table.commitId),
  }),
);

export const zombieCommitment = onchainTable(
  "zombie_commitment",
  (t) => ({
    commitId: t.bigint().primaryKey(),
    qualifyingWallet: t.hex().notNull(),
    tokenId: t.bigint().notNull(),
    index: t.bigint().notNull(),
    committer: t.hex().notNull(),
    committedOwner: t.hex().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    revealed: t.boolean().notNull().default(false),
    cancelled: t.boolean().notNull().default(false),
    poolIndex: t.bigint(),
    revealBlockNumber: t.bigint(),
    revealTimestamp: t.bigint(),
    revealTxHash: t.hex(),
    cancelBlockNumber: t.bigint(),
    cancelTimestamp: t.bigint(),
    cancelTxHash: t.hex(),
  }),
  (table) => ({
    walletIdx: index().on(table.qualifyingWallet),
    tokenIdx: index().on(table.tokenId),
    txHashIdx: index().on(table.txHash),
  }),
);

export const zombieConfig = onchainTable(
  "zombie_config",
  (t) => ({
    id: t.text().primaryKey(),
    paused: t.boolean().notNull().default(true),
    merkleRoot: t.hex(),
    seedBlock: t.bigint(),
    seed: t.hex(),
    seedLocked: t.boolean().notNull().default(false),
    poolSize: t.integer().notNull().default(0),
    poolSealed: t.boolean().notNull().default(false),
    blockNumber: t.bigint(),
    timestamp: t.bigint(),
    txHash: t.hex(),
  }),
);

// ──────────────────────────────────────────────
//  NormiesLegendaryCanvas
// ──────────────────────────────────────────────

export const legendaryCanvasTrait = onchainTable(
  "legendary_canvas_trait",
  (t) => ({
    tokenId: t.bigint().primaryKey(),
    isLegendary: t.boolean().notNull().default(false),
    artistName: t.text(),
    operator: t.hex(),
    blockNumber: t.bigint(),
    timestamp: t.bigint(),
    txHash: t.hex(),
  }),
  (table) => ({
    activeIdx: index().on(table.isLegendary),
    operatorIdx: index().on(table.operator),
  }),
);

export const legendaryCanvasTraitEvent = onchainTable(
  "legendary_canvas_trait_event",
  (t) => ({
    id: t.text().primaryKey(),
    tokenId: t.bigint().notNull(),
    isLegendary: t.boolean().notNull().default(false),
    artistName: t.text(),
    operator: t.hex(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    tokenBlockIdx: index().on(table.tokenId, table.blockNumber),
    blockIdx: index().on(table.blockNumber),
    activeIdx: index().on(table.isLegendary),
  }),
);

export const rarityLegendaryConfig = onchainTable(
  "rarity_legendary_config",
  (t) => ({
    id: t.text().primaryKey(),
    currentJson: t.text().notNull(),
    upcomingJson: t.text().notNull(),
    updatedAt: t.bigint().notNull(),
    updatedBy: t.text(),
  }),
);

// ──────────────────────────────────────────────
//  Adapter8004 — AgentBound
//
//  One row per binding (standard × tokenContract × tokenId). PK is composite
//  so the same token across different standards/contracts can coexist; the
//  public API filters to Normies before exposing rows.
// ──────────────────────────────────────────────
export const agentBinding = onchainTable(
  "agent_binding",
  (t) => ({
    // <standard>:<tokenContract>:<tokenId>, e.g. "0:0x9eb...:93"
    id: t.text().primaryKey(),
    agentId: t.bigint().notNull(),
    standard: t.integer().notNull(),
    tokenContract: t.hex().notNull(),
    tokenId: t.bigint().notNull(),
    registeredBy: t.hex().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    agentIdIdx: index().on(table.agentId),
    tokenIdx: index().on(table.tokenContract, table.tokenId),
    registeredByIdx: index().on(table.registeredBy),
  }),
);

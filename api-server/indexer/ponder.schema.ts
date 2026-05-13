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

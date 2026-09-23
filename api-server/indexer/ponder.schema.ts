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

// Per-token canvas state. `actionPoints` is the pixels attached to the token
// (V1 reveals accumulate it, V2 ledger events set it outright). `lockedPixels`
// is the popcount of the latest overlay; `actionPoints - lockedPixels` is what
// the owner can withdraw without a forced overlay reset.
export const canvasTokenState = onchainTable(
  "canvas_token_state",
  (t) => ({
    tokenId: t.bigint().primaryKey(),
    actionPoints: t.bigint().notNull().default(0n),
    customized: t.boolean().notNull().default(false),
    delegate: t.hex().notNull(),
    delegateSetBy: t.hex().notNull(),
    latestTransformBitmap: t.hex(),
    gridSize: t.integer().notNull().default(40),
    baseCleared: t.boolean().notNull().default(false),
    migrated: t.boolean().notNull().default(false),
    lockedPixels: t.integer().notNull().default(0),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
);

// Burn commitments from both canvas generations. V1 and V2 commit ids both
// start at 0, so the primary key is `${contractVersion}-${commitId}`.
export const burnCommitment = onchainTable(
  "burn_commitment",
  (t) => ({
    id: t.text().primaryKey(),
    commitId: t.bigint().notNull(),
    contractVersion: t.integer().notNull().default(1),
    owner: t.hex().notNull(),
    // 0 and meaningless when toWallet is true.
    receiverTokenId: t.bigint().notNull(),
    // V2 wallet burn: the reward and carried pixels went to the owner's wallet, not a Normie.
    toWallet: t.boolean().notNull().default(false),
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
    commitIdx: index().on(table.contractVersion, table.commitId),
    ownerIdx: index().on(table.owner),
    receiverIdx: index().on(table.receiverTokenId),
    txHashIdx: index().on(table.txHash),
    revealedIdx: index().on(table.revealed),
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

// One row per overlay version. V2 rows are keyed `${txHash}-${tokenId}`
// (`-clear` suffix for resets); `gridSize` says how to read `transformBitmap`.
export const pixelTransform = onchainTable(
  "pixel_transform",
  (t) => ({
    id: t.text().primaryKey(),
    tokenId: t.bigint().notNull(),
    transformer: t.hex().notNull(),
    changeCount: t.integer().notNull(),
    newPixelCount: t.integer().notNull(),
    transformBitmap: t.hex(),
    gridSize: t.integer().notNull().default(40),
    cleared: t.boolean().notNull().default(false),
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
//  Pixel ledger
// ──────────────────────────────────────────────

export const pixelBalance = onchainTable(
  "pixel_balance",
  (t) => ({
    address: t.hex().primaryKey(),
    balance: t.bigint().notNull().default(0n),
    updatedBlock: t.bigint().notNull(),
  }),
  (table) => ({
    balanceIdx: index().on(table.balance),
  }),
);

export const pixelLedgerEvent = onchainTable(
  "pixel_ledger_event",
  (t) => ({
    id: t.text().primaryKey(),
    kind: t.text().notNull(), // "move" | "attached"
    from: t.hex(),
    to: t.hex(),
    tokenId: t.bigint(),
    amount: t.bigint().notNull(),
    newAttached: t.bigint(),
    reason: t.text(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    fromIdx: index().on(table.from),
    toIdx: index().on(table.to),
    tokenIdx: index().on(table.tokenId),
    blockIdx: index().on(table.blockNumber),
  }),
);

export const pixelSupply = onchainTable(
  "pixel_supply",
  (t) => ({
    id: t.text().primaryKey(),
    totalWallet: t.bigint().notNull().default(0n),
    totalAttached: t.bigint().notNull().default(0n),
    totalMigrated: t.integer().notNull().default(0),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
);

// ──────────────────────────────────────────────
//  Revenue share
// ──────────────────────────────────────────────

export const revshareEpoch = onchainTable(
  "revshare_epoch",
  (t) => ({
    epochId: t.bigint().primaryKey(),
    root: t.hex().notNull(),
    amount: t.bigint().notNull(),
    claimed: t.bigint().notNull().default(0n),
    claims: t.integer().notNull().default(0),
    fromBlock: t.bigint().notNull(),
    toBlock: t.bigint().notNull(),
    claimableAt: t.bigint().notNull(),
    sweepableAt: t.bigint().notNull(),
    configHash: t.hex().notNull(),
    dataURI: t.text().notNull(),
    status: t.text().notNull(), // "posted" | "cancelled" | "swept"
    sweptAmount: t.bigint(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    statusIdx: index().on(table.status),
  }),
);

export const revshareClaim = onchainTable(
  "revshare_claim",
  (t) => ({
    id: t.text().primaryKey(), // `${epochId}-${index}`
    epochId: t.bigint().notNull(),
    index: t.bigint().notNull(),
    account: t.hex().notNull(),
    amount: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    accountIdx: index().on(table.account),
    epochIdx: index().on(table.epochId),
  }),
);

export const revshareRelease = onchainTable("revshare_release", (t) => ({
  id: t.text().primaryKey(), // `${block}-${logIndex}`
  toPool: t.bigint().notNull(),
  toTeam: t.bigint().notNull(),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
  txHash: t.hex().notNull(),
}));

export const revshareStats = onchainTable("revshare_stats", (t) => ({
  id: t.text().primaryKey(),
  epochs: t.integer().notNull().default(0),
  allocatedWei: t.bigint().notNull().default(0n),
  claimedWei: t.bigint().notNull().default(0n),
  sweptWei: t.bigint().notNull().default(0n),
  royaltiesToPoolWei: t.bigint().notNull().default(0n),
  blockNumber: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
}));

// ──────────────────────────────────────────────
//  Pixel market
// ──────────────────────────────────────────────

export const marketListing = onchainTable(
  "market_listing",
  (t) => ({
    listingId: t.bigint().primaryKey(),
    seller: t.hex().notNull(),
    pricePerPixel: t.bigint().notNull(),
    amount: t.integer().notNull(),
    remaining: t.integer().notNull(),
    partialFill: t.boolean().notNull(),
    expiry: t.bigint().notNull(),
    status: t.text().notNull(), // "active" | "filled" | "cancelled"
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    updatedBlockNumber: t.bigint().notNull(),
    updatedTimestamp: t.bigint().notNull(),
    updatedTxHash: t.hex().notNull(),
  }),
  (table) => ({
    sellerIdx: index().on(table.seller),
    statusIdx: index().on(table.status),
    priceIdx: index().on(table.pricePerPixel),
  }),
);

export const marketFill = onchainTable(
  "market_fill",
  (t) => ({
    id: t.text().primaryKey(),
    listingId: t.bigint().notNull(),
    buyer: t.hex().notNull(),
    seller: t.hex().notNull(),
    amount: t.integer().notNull(),
    pricePerPixel: t.bigint().notNull(),
    grossWei: t.bigint().notNull(),
    feeWei: t.bigint().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
    logIndex: t.integer().notNull(),
  }),
  (table) => ({
    listingIdx: index().on(table.listingId),
    buyerIdx: index().on(table.buyer),
    sellerIdx: index().on(table.seller),
    timestampIdx: index().on(table.timestamp),
  }),
);

export const marketStats = onchainTable(
  "market_stats",
  (t) => ({
    id: t.text().primaryKey(),
    volumeWei: t.bigint().notNull().default(0n),
    feesWei: t.bigint().notNull().default(0n),
    feesCollectedWei: t.bigint().notNull().default(0n),
    pixelsTraded: t.bigint().notNull().default(0n),
    fills: t.integer().notNull().default(0),
    listings: t.integer().notNull().default(0),
    feeBps: t.integer().notNull().default(1000),
    revenueShareBps: t.integer().notNull().default(5000),
    paused: t.boolean().notNull().default(true),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
  }),
);

// Pixels spent on canvas services (enlargement, blank canvas).
export const canvasSinkEvent = onchainTable(
  "canvas_sink_event",
  (t) => ({
    id: t.text().primaryKey(),
    tokenId: t.bigint().notNull(),
    kind: t.text().notNull(), // "enlarge" | "clearBase"
    fromSize: t.integer(),
    toSize: t.integer(),
    cost: t.bigint().notNull(),
    source: t.text().notNull(), // "wallet" | "attached"
    by: t.hex().notNull(),
    blockNumber: t.bigint().notNull(),
    timestamp: t.bigint().notNull(),
    txHash: t.hex().notNull(),
  }),
  (table) => ({
    tokenIdx: index().on(table.tokenId),
    kindIdx: index().on(table.kind),
    blockIdx: index().on(table.blockNumber),
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

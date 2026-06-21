import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { eq, desc, count, sum, asc, and, gt, lt, lte, inArray } from "ponder";

const app = new Hono();
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const RARITY_LEGENDARY_CONFIG_ID = "default";
const writableDb = db as typeof db & {
  insert: (table: unknown) => {
    values: (value: unknown) => {
      onConflictDoNothing: () => Promise<unknown>;
      onConflictDoUpdate: (value: unknown) => Promise<unknown>;
    };
  };
};

const RARITY_LEGENDARY_DEFAULT = {
  current: [
    { id: 603, artist: "a.c.k." },
    { id: 45, artist: "Snowfro" },
    { id: 6576, artist: "Deekay" },
    { id: 4698, artist: "Jack Butcher" },
    { id: 5974, artist: "Timpers" },
    { id: 7409, artist: "PIV" },
    { id: 4354, artist: "Serc" },
  ],
  upcoming: [
    { id: 0, artist: "" },
    { id: 9993, artist: "Serc" },
  ],
};

// ──────────────────────────────────────────────
//  Helpers
// ──────────────────────────────────────────────

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
  const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50), 1), 100);
  const offset = Math.max(Number(c.req.query("offset") ?? 0), 0);
  return { limit, offset };
}

function parseBulkPagination(c: { req: { query: (key: string) => string | undefined } }) {
  const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 10_000), 1), 10_000);
  const offset = Math.max(Number(c.req.query("offset") ?? 0), 0);
  return { limit, offset };
}

function serializeBigints<T extends Record<string, unknown>>(row: T): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) {
    result[key] = typeof value === "bigint" ? value.toString() : value;
  }
  return result;
}

function parseTokenIds(raw: unknown): bigint[] {
  if (!Array.isArray(raw)) return [];
  const ids = new Set<bigint>();
  for (const value of raw.slice(0, 1000)) {
    try {
      ids.add(BigInt(String(value)));
    } catch {
      // skip malformed token ids
    }
  }
  return Array.from(ids);
}

function emptyZombieState(tokenId: bigint): Record<string, unknown> {
  return {
    tokenId: tokenId.toString(),
    isZombie: false,
    poolIndex: null,
    bitmap: null,
    attributesJson: null,
    qualifyingWallet: null,
    commitId: null,
    blockNumber: null,
    timestamp: null,
    txHash: null,
  };
}

function defaultZombieStatus(): Record<string, unknown> {
  return {
    paused: true,
    merkleRoot: null,
    seedBlock: null,
    seed: null,
    seedLocked: false,
    poolSize: 0,
    poolSealed: false,
    blockNumber: null,
    timestamp: null,
    txHash: null,
  };
}

function emptyLegendaryCanvasState(tokenId: bigint): Record<string, unknown> {
  return {
    tokenId: tokenId.toString(),
    isLegendary: false,
    artistName: null,
    operator: null,
    blockNumber: null,
    timestamp: null,
    txHash: null,
  };
}

function buildBurnSummaries(
  commitments: Array<{
    receiverTokenId: bigint;
    tokenCount: number;
    txHash: `0x${string}`;
  }>,
  burnedTokens: Array<{
    tokenId: bigint;
    txHash: `0x${string}`;
  }>,
) {
  const burnedByTx = new Map<string, bigint[]>();
  for (const row of burnedTokens) {
    const key = row.txHash.toLowerCase();
    const rows = burnedByTx.get(key) ?? [];
    rows.push(row.tokenId);
    burnedByTx.set(key, rows);
  }

  const receiverBurnedTokens = new Map<bigint, bigint[]>();
  const directCounts = new Map<bigint, number>();
  for (const commitment of commitments) {
    const receiverId = commitment.receiverTokenId;
    directCounts.set(receiverId, (directCounts.get(receiverId) ?? 0) + commitment.tokenCount);

    const tokenIds = burnedByTx.get(commitment.txHash.toLowerCase()) ?? [];
    if (tokenIds.length > 0) {
      const rows = receiverBurnedTokens.get(receiverId) ?? [];
      rows.push(...tokenIds);
      receiverBurnedTokens.set(receiverId, rows);
    }
  }

  function resolveDeep(tokenId: bigint, visited: Set<bigint>): number {
    if (visited.has(tokenId)) return 0;
    visited.add(tokenId);

    const tokenIds = receiverBurnedTokens.get(tokenId) ?? [];
    let total = 0;
    for (const burnedTokenId of tokenIds) {
      total += 1;
      if (receiverBurnedTokens.has(burnedTokenId)) {
        total += resolveDeep(burnedTokenId, visited);
      }
    }
    return total;
  }

  const recursiveCounts = new Map<bigint, number>();
  for (const receiverId of receiverBurnedTokens.keys()) {
    recursiveCounts.set(receiverId, resolveDeep(receiverId, new Set()));
  }

  return { directCounts, recursiveCounts };
}

function numberMapToRecord(map: Map<bigint, number>): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [tokenId, count] of map) out[tokenId.toString()] = count;
  return out;
}

function parseBlockNumberParam(raw: string | undefined): bigint | null {
  if (!raw || !/^\d+$/.test(raw)) return null;
  const blockNumber = BigInt(raw);
  return blockNumber >= 0n ? blockNumber : null;
}

function logIndexFromId(id: string): number {
  const raw = id.split("-").pop();
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

function compareBlockLog(
  a: { id?: string; blockNumber: bigint; logIndex?: number },
  b: { id?: string; blockNumber: bigint; logIndex?: number },
): number {
  if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? -1 : 1;
  const aLog = a.logIndex ?? (a.id ? logIndexFromId(a.id) : 0);
  const bLog = b.logIndex ?? (b.id ? logIndexFromId(b.id) : 0);
  return aLog - bLog;
}

function latestByToken<T extends { tokenId: bigint; blockNumber: bigint; id?: string; logIndex?: number }>(
  rows: T[],
): Map<bigint, T> {
  const latest = new Map<bigint, T>();
  for (const row of [...rows].sort(compareBlockLog)) {
    latest.set(row.tokenId, row);
  }
  return latest;
}

function buildHistoricalOwners(
  transfers: Array<{
    tokenId: bigint;
    from: `0x${string}`;
    to: `0x${string}`;
    blockNumber: bigint;
    logIndex: number;
  }>,
): Map<bigint, `0x${string}`> {
  const owners = new Map<bigint, `0x${string}`>();
  for (const row of [...transfers].sort(compareBlockLog)) {
    if (row.to.toLowerCase() === ZERO_ADDRESS) owners.delete(row.tokenId);
    else owners.set(row.tokenId, row.to);
  }
  return owners;
}

function buildHistoricalCanvasStates(
  blockNumber: bigint,
  tokenRows: Array<{ tokenId: bigint; blockNumber: bigint; timestamp: bigint; txHash: `0x${string}` }>,
  transforms: Array<{
    id: string;
    tokenId: bigint;
    newPixelCount: number;
    transformBitmap: `0x${string}` | null;
    blockNumber: bigint;
    timestamp: bigint;
    txHash: `0x${string}`;
  }>,
  commitments: Array<{
    receiverTokenId: bigint;
    revealed: boolean;
    totalActions: bigint | null;
    revealBlockNumber: bigint | null;
    revealTimestamp: bigint | null;
    revealTxHash: `0x${string}` | null;
  }>,
) {
  const actionPoints = new Map<bigint, bigint>();
  const actionMeta = new Map<bigint, { blockNumber: bigint; timestamp: bigint; txHash: `0x${string}` }>();
  for (const row of commitments) {
    if (!row.revealed || row.revealBlockNumber === null || row.totalActions === null) continue;
    if (row.revealBlockNumber > blockNumber) continue;
    const current = actionPoints.get(row.receiverTokenId) ?? 0n;
    actionPoints.set(row.receiverTokenId, current + row.totalActions);
    const nextMeta = {
      blockNumber: row.revealBlockNumber,
      timestamp: row.revealTimestamp ?? 0n,
      txHash: row.revealTxHash ?? ZERO_ADDRESS,
    };
    const currentMeta = actionMeta.get(row.receiverTokenId);
    if (!currentMeta || compareBlockLog(nextMeta, currentMeta) >= 0) {
      actionMeta.set(row.receiverTokenId, nextMeta);
    }
  }

  const latestTransforms = latestByToken(transforms);
  const states = new Map<string, Record<string, unknown>>();
  const pixelCounts = new Map<string, number>();
  for (const row of tokenRows) {
    const transform = latestTransforms.get(row.tokenId);
    const apMeta = actionMeta.get(row.tokenId);
    const meta = transform && (!apMeta || compareBlockLog(transform, apMeta) >= 0)
      ? transform
      : apMeta ?? row;

    states.set(row.tokenId.toString(), {
      tokenId: row.tokenId.toString(),
      actionPoints: (actionPoints.get(row.tokenId) ?? 0n).toString(),
      customized: Boolean(transform),
      delegate: ZERO_ADDRESS,
      delegateSetBy: ZERO_ADDRESS,
      latestTransformBitmap: transform?.transformBitmap ?? null,
      blockNumber: meta.blockNumber.toString(),
      timestamp: meta.timestamp.toString(),
      txHash: meta.txHash,
    });
    if (transform) pixelCounts.set(row.tokenId.toString(), transform.newPixelCount);
  }
  return { states, pixelCounts };
}

function buildHistoricalZombieStates(
  blockNumber: bigint,
  commitments: Array<{
    commitId: bigint;
    qualifyingWallet: `0x${string}`;
    tokenId: bigint;
    revealed: boolean;
    cancelled: boolean;
    poolIndex: bigint | null;
    revealBlockNumber: bigint | null;
    revealTimestamp: bigint | null;
    revealTxHash: `0x${string}` | null;
    cancelBlockNumber: bigint | null;
  }>,
  poolItems: Array<{ poolIndex: bigint; bitmap: `0x${string}`; attributesJson: string }>,
) {
  const poolByIndex = new Map(poolItems.map((item) => [item.poolIndex.toString(), item]));
  const latest = new Map<bigint, typeof commitments[number]>();
  for (const row of commitments) {
    if (!row.revealed || row.revealBlockNumber === null || row.poolIndex === null) continue;
    if (row.revealBlockNumber > blockNumber) continue;
    if (row.cancelled && row.cancelBlockNumber !== null && row.cancelBlockNumber <= blockNumber) continue;
    const existing = latest.get(row.tokenId);
    if (!existing || (existing.revealBlockNumber ?? 0n) < row.revealBlockNumber) latest.set(row.tokenId, row);
  }

  const states = new Map<string, Record<string, unknown>>();
  for (const row of latest.values()) {
    if (row.poolIndex === null || row.revealBlockNumber === null) continue;
    const poolItem = poolByIndex.get(row.poolIndex.toString());
    states.set(row.tokenId.toString(), {
      tokenId: row.tokenId.toString(),
      isZombie: true,
      poolIndex: row.poolIndex.toString(),
      bitmap: poolItem?.bitmap ?? null,
      attributesJson: poolItem?.attributesJson ?? null,
      qualifyingWallet: row.qualifyingWallet,
      commitId: row.commitId.toString(),
      blockNumber: row.revealBlockNumber.toString(),
      timestamp: row.revealTimestamp?.toString() ?? null,
      txHash: row.revealTxHash ?? null,
    });
  }
  return states;
}

function buildHistoricalLegendaryCanvasStates(
  events: Array<{
    id: string;
    tokenId: bigint;
    isLegendary: boolean;
    artistName: string | null;
    operator: `0x${string}` | null;
    blockNumber: bigint;
    timestamp: bigint;
    txHash: `0x${string}`;
  }>,
) {
  const latest = latestByToken(events);
  const states = new Map<string, Record<string, unknown>>();
  for (const row of latest.values()) {
    states.set(row.tokenId.toString(), {
      tokenId: row.tokenId.toString(),
      isLegendary: row.isLegendary,
      artistName: row.artistName,
      operator: row.operator,
      blockNumber: row.blockNumber.toString(),
      timestamp: row.timestamp.toString(),
      txHash: row.txHash,
    });
  }
  return states;
}

function parseJsonArray(raw: string): unknown[] {
  try {
    const parsed = JSON.parse(raw) as unknown;
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

async function getRarityLegendaryConfigRow() {
  const [existing] = await db
    .select()
    .from(schema.rarityLegendaryConfig)
    .where(eq(schema.rarityLegendaryConfig.id, RARITY_LEGENDARY_CONFIG_ID))
    .limit(1);
  if (existing) return existing;

  const now = BigInt(Math.floor(Date.now() / 1000));
  await writableDb
    .insert(schema.rarityLegendaryConfig)
    .values({
      id: RARITY_LEGENDARY_CONFIG_ID,
      currentJson: JSON.stringify(RARITY_LEGENDARY_DEFAULT.current),
      upcomingJson: JSON.stringify(RARITY_LEGENDARY_DEFAULT.upcoming),
      updatedAt: now,
      updatedBy: "seed",
    })
    .onConflictDoNothing();

  const [seeded] = await db
    .select()
    .from(schema.rarityLegendaryConfig)
    .where(eq(schema.rarityLegendaryConfig.id, RARITY_LEGENDARY_CONFIG_ID))
    .limit(1);

  return seeded ?? {
    id: RARITY_LEGENDARY_CONFIG_ID,
    currentJson: JSON.stringify(RARITY_LEGENDARY_DEFAULT.current),
    upcomingJson: JSON.stringify(RARITY_LEGENDARY_DEFAULT.upcoming),
    updatedAt: now,
    updatedBy: "seed",
  };
}

function serializeRarityLegendaryConfig(row: {
  currentJson: string;
  upcomingJson: string;
  updatedAt: bigint;
  updatedBy: string | null;
}) {
  return {
    current: parseJsonArray(row.currentJson),
    upcoming: parseJsonArray(row.upcomingJson),
    updatedAt: row.updatedAt.toString(),
    updatedBy: row.updatedBy,
  };
}

// ──────────────────────────────────────────────
//  Existing: Ownership & Delegation
// ──────────────────────────────────────────────

app.get("/owner/:tokenId", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));

  const [row] = await db
    .select({ owner: schema.normieOwner.owner })
    .from(schema.normieOwner)
    .where(eq(schema.normieOwner.tokenId, tokenId))
    .limit(1);

  if (!row) return c.json({ error: "Token not found" }, 404);

  return c.json({ tokenId: tokenId.toString(), owner: row.owner });
});

app.get("/tokens/:address", async (c) => {
  const address = c.req.param("address").toLowerCase() as `0x${string}`;

  const rows = await db
    .select({ tokenId: schema.normieOwner.tokenId })
    .from(schema.normieOwner)
    .where(eq(schema.normieOwner.owner, address));

  return c.json(rows.map((r) => r.tokenId.toString()));
});

app.get("/delegations/:address", async (c) => {
  const address = c.req.param("address").toLowerCase() as `0x${string}`;

  const rows = await db
    .select({ tokenId: schema.delegation.tokenId })
    .from(schema.delegation)
    .where(eq(schema.delegation.delegate, address));

  return c.json(rows.map((r) => r.tokenId.toString()));
});

// ──────────────────────────────────────────────
//  Token data & Canvas state
// ──────────────────────────────────────────────

app.get("/token-data/count", async (c) => {
  const [row] = await db.select({ total: count() }).from(schema.tokenData);
  return c.json({ count: row?.total ?? 0 });
});

app.get("/token-data/all", async (c) => {
  const { limit, offset } = parseBulkPagination(c);

  const rows = await db
    .select()
    .from(schema.tokenData)
    .orderBy(asc(schema.tokenData.tokenId))
    .limit(limit + 1)
    .offset(offset);

  const page = rows.slice(0, limit);
  return c.json({
    tokens: page.map(serializeBigints),
    hasMore: rows.length > limit,
  });
});

app.get("/token-data/:tokenId", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));

  const [row] = await db
    .select()
    .from(schema.tokenData)
    .where(eq(schema.tokenData.tokenId, tokenId))
    .limit(1);

  if (!row) return c.json({ error: "Token data not found" }, 404);
  return c.json(serializeBigints(row));
});

app.post("/token-data/batch", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { tokenIds?: unknown };
  const ids = parseTokenIds(body.tokenIds);
  if (ids.length === 0) return c.json({ tokens: {} });

  const rows = await db
    .select()
    .from(schema.tokenData)
    .where(inArray(schema.tokenData.tokenId, ids));

  const tokens: Record<string, unknown> = {};
  for (const row of rows) tokens[row.tokenId.toString()] = serializeBigints(row);
  return c.json({ tokens });
});

app.get("/canvas-state/:tokenId", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));

  const [row] = await db
    .select()
    .from(schema.canvasTokenState)
    .where(eq(schema.canvasTokenState.tokenId, tokenId))
    .limit(1);

  if (!row) return c.json({ error: "Canvas state not found" }, 404);
  return c.json(serializeBigints(row));
});

app.post("/canvas-state/batch", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { tokenIds?: unknown };
  const ids = parseTokenIds(body.tokenIds);
  if (ids.length === 0) return c.json({ states: {} });

  const rows = await db
    .select()
    .from(schema.canvasTokenState)
    .where(inArray(schema.canvasTokenState.tokenId, ids));

  const states: Record<string, unknown> = {};
  for (const row of rows) states[row.tokenId.toString()] = serializeBigints(row);
  return c.json({ states });
});

// ──────────────────────────────────────────────
//  Zombie state
// ──────────────────────────────────────────────

app.get("/zombie-state/:tokenId", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));

  const [row] = await db
    .select()
    .from(schema.zombieTokenState)
    .where(eq(schema.zombieTokenState.tokenId, tokenId))
    .limit(1);

  return c.json(row ? serializeBigints(row) : emptyZombieState(tokenId));
});

app.post("/zombie-state/batch", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { tokenIds?: unknown };
  const ids = parseTokenIds(body.tokenIds);
  if (ids.length === 0) return c.json({ states: {} });

  const rows = await db
    .select()
    .from(schema.zombieTokenState)
    .where(inArray(schema.zombieTokenState.tokenId, ids));

  const states: Record<string, unknown> = {};
  for (const tokenId of ids) states[tokenId.toString()] = emptyZombieState(tokenId);
  for (const row of rows) states[row.tokenId.toString()] = serializeBigints(row);
  return c.json({ states });
});

app.get("/zombies/status", async (c) => {
  const [row] = await db
    .select()
    .from(schema.zombieConfig)
    .where(eq(schema.zombieConfig.id, "global"))
    .limit(1);

  return c.json(row ? serializeBigints(row) : defaultZombieStatus());
});

app.get("/zombies/conversions", async (c) => {
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.zombieCommitment)
    .orderBy(desc(schema.zombieCommitment.blockNumber))
    .limit(limit)
    .offset(offset);

  return c.json(rows.map(serializeBigints));
});

app.get("/zombies/wallet/:address", async (c) => {
  const address = c.req.param("address").toLowerCase() as `0x${string}`;
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.zombieCommitment)
    .where(eq(schema.zombieCommitment.qualifyingWallet, address))
    .orderBy(desc(schema.zombieCommitment.blockNumber))
    .limit(limit)
    .offset(offset);

  return c.json(rows.map(serializeBigints));
});

app.get("/zombies/token/:tokenId", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));

  const rows = await db
    .select()
    .from(schema.zombieCommitment)
    .where(eq(schema.zombieCommitment.tokenId, tokenId))
    .orderBy(desc(schema.zombieCommitment.blockNumber));

  return c.json(rows.map(serializeBigints));
});

// ──────────────────────────────────────────────
//  Legendary Canvas
// ──────────────────────────────────────────────

app.get("/legendary-canvas/:tokenId", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));

  const [row] = await db
    .select()
    .from(schema.legendaryCanvasTrait)
    .where(eq(schema.legendaryCanvasTrait.tokenId, tokenId))
    .limit(1);

  return c.json(row ? serializeBigints(row) : emptyLegendaryCanvasState(tokenId));
});

app.post("/legendary-canvas/batch", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { tokenIds?: unknown };
  const ids = parseTokenIds(body.tokenIds);
  if (ids.length === 0) return c.json({ states: {} });

  const rows = await db
    .select()
    .from(schema.legendaryCanvasTrait)
    .where(inArray(schema.legendaryCanvasTrait.tokenId, ids));

  const states: Record<string, unknown> = {};
  for (const tokenId of ids) states[tokenId.toString()] = emptyLegendaryCanvasState(tokenId);
  for (const row of rows) states[row.tokenId.toString()] = serializeBigints(row);
  return c.json({ states });
});

app.get("/legendary-canvas", async (c) => {
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.legendaryCanvasTrait)
    .where(eq(schema.legendaryCanvasTrait.isLegendary, true))
    .orderBy(desc(schema.legendaryCanvasTrait.blockNumber))
    .limit(limit)
    .offset(offset);

  return c.json(rows.map(serializeBigints));
});

app.get("/rarity/legendary-config", async (c) => {
  return c.json(serializeRarityLegendaryConfig(await getRarityLegendaryConfigRow()));
});

app.put("/rarity/legendary-config", async (c) => {
  const body = (await c.req.json().catch(() => null)) as {
    current?: unknown;
    upcoming?: unknown;
    updatedBy?: unknown;
  } | null;
  if (!body || !Array.isArray(body.current) || !Array.isArray(body.upcoming)) {
    return c.json({ error: "Body must include current[] and upcoming[] arrays" }, 400);
  }

  const now = BigInt(Math.floor(Date.now() / 1000));
  const updatedBy = typeof body.updatedBy === "string" ? body.updatedBy.slice(0, 120) : null;
  await writableDb
    .insert(schema.rarityLegendaryConfig)
    .values({
      id: RARITY_LEGENDARY_CONFIG_ID,
      currentJson: JSON.stringify(body.current),
      upcomingJson: JSON.stringify(body.upcoming),
      updatedAt: now,
      updatedBy,
    })
    .onConflictDoUpdate({
      currentJson: JSON.stringify(body.current),
      upcomingJson: JSON.stringify(body.upcoming),
      updatedAt: now,
      updatedBy,
    });

  return c.json(serializeRarityLegendaryConfig(await getRarityLegendaryConfigRow()));
});

// ──────────────────────────────────────────────
//  Burns: Commitments
// ──────────────────────────────────────────────

app.get("/burns", async (c) => {
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.burnCommitment)
    .orderBy(desc(schema.burnCommitment.blockNumber))
    .limit(limit)
    .offset(offset);

  return c.json(rows.map(serializeBigints));
});

app.get("/burns/:commitId", async (c) => {
  const commitId = BigInt(c.req.param("commitId"));

  const [commitment] = await db
    .select()
    .from(schema.burnCommitment)
    .where(eq(schema.burnCommitment.commitId, commitId))
    .limit(1);

  if (!commitment) return c.json({ error: "Commitment not found" }, 404);

  // Join burned tokens by txHash (Transfer events in the same tx as BurnCommitted)
  const tokens = await db
    .select()
    .from(schema.burnedToken)
    .where(eq(schema.burnedToken.txHash, commitment.txHash))
    .orderBy(asc(schema.burnedToken.tokenId));

  const serialized = serializeBigints(commitment);
  // Parse pixelCounts JSON back to array if present
  if (typeof serialized.pixelCounts === "string") {
    try {
      serialized.pixelCounts = JSON.parse(serialized.pixelCounts as string);
    } catch { /* leave as string */ }
  }

  return c.json({
    ...serialized,
    burnedTokens: tokens.map(serializeBigints),
  });
});

app.get("/burns/address/:address", async (c) => {
  const address = c.req.param("address").toLowerCase() as `0x${string}`;
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.burnCommitment)
    .where(eq(schema.burnCommitment.owner, address))
    .orderBy(desc(schema.burnCommitment.blockNumber))
    .limit(limit)
    .offset(offset);

  return c.json(rows.map(serializeBigints));
});

app.get("/burns/receiver/:tokenId", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.burnCommitment)
    .where(eq(schema.burnCommitment.receiverTokenId, tokenId))
    .orderBy(desc(schema.burnCommitment.blockNumber))
    .limit(limit)
    .offset(offset);

  return c.json(rows.map(serializeBigints));
});

// ──────────────────────────────────────────────
//  Burns: Individual Burned Tokens
// ──────────────────────────────────────────────

app.get("/burned-tokens", async (c) => {
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.burnedToken)
    .orderBy(desc(schema.burnedToken.blockNumber))
    .limit(limit)
    .offset(offset);

  return c.json(rows.map(serializeBigints));
});

app.get("/burned-tokens/:tokenId", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));

  const [row] = await db
    .select()
    .from(schema.burnedToken)
    .where(eq(schema.burnedToken.tokenId, tokenId))
    .limit(1);

  if (!row) return c.json({ error: "Token not found in burn records" }, 404);

  // Find the associated burn commitment via txHash
  const [commitment] = await db
    .select()
    .from(schema.burnCommitment)
    .where(eq(schema.burnCommitment.txHash, row.txHash))
    .limit(1);

  return c.json({
    ...serializeBigints(row),
    commitment: commitment ? serializeBigints(commitment) : null,
  });
});

// ──────────────────────────────────────────────
//  Transforms
// ──────────────────────────────────────────────

app.get("/transforms", async (c) => {
  const { limit, offset } = parsePagination(c);
  const afterTimestampRaw = c.req.query("after_timestamp") ?? c.req.query("since_timestamp");
  const sortRaw = c.req.query("sort");
  const sort = sortRaw === "asc" || sortRaw === "desc"
    ? sortRaw
    : afterTimestampRaw
      ? "asc"
      : "desc";

  let afterTimestamp: bigint | undefined;
  if (afterTimestampRaw !== undefined) {
    try {
      afterTimestamp = BigInt(afterTimestampRaw);
      if (afterTimestamp < 0n) throw new Error("negative timestamp");
    } catch {
      return c.json({ error: "`after_timestamp` must be a non-negative unix timestamp string" }, 400);
    }
  }

  const rows = afterTimestamp !== undefined
    ? sort === "asc"
      ? await db
          .select()
          .from(schema.pixelTransform)
          .where(gt(schema.pixelTransform.timestamp, afterTimestamp))
          .orderBy(asc(schema.pixelTransform.timestamp), asc(schema.pixelTransform.blockNumber))
          .limit(limit + 1)
          .offset(offset)
      : await db
          .select()
          .from(schema.pixelTransform)
          .where(gt(schema.pixelTransform.timestamp, afterTimestamp))
          .orderBy(desc(schema.pixelTransform.timestamp), desc(schema.pixelTransform.blockNumber))
          .limit(limit + 1)
          .offset(offset)
    : sort === "asc"
      ? await db
          .select()
          .from(schema.pixelTransform)
          .orderBy(asc(schema.pixelTransform.timestamp), asc(schema.pixelTransform.blockNumber))
          .limit(limit + 1)
          .offset(offset)
      : await db
          .select()
          .from(schema.pixelTransform)
          .orderBy(desc(schema.pixelTransform.timestamp), desc(schema.pixelTransform.blockNumber))
          .limit(limit + 1)
          .offset(offset);

  const page = rows.slice(0, limit);
  const events = page.map((r) => {
    const serialized = serializeBigints(r);
    delete serialized.transformBitmap;
    return serialized;
  });
  const tokenIds = Array.from(new Set(page.map((r) => r.tokenId.toString())));

  return c.json({
    events,
    tokenIds,
    count: events.length,
    hasMore: rows.length > limit,
    afterTimestamp: afterTimestamp?.toString() ?? null,
  });
});

app.get("/transforms/:tokenId", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));
  const { limit, offset } = parsePagination(c);
  const includeBitmap = c.req.query("bitmap") === "true";

  const rows = await db
    .select()
    .from(schema.pixelTransform)
    .where(eq(schema.pixelTransform.tokenId, tokenId))
    .orderBy(desc(schema.pixelTransform.blockNumber))
    .limit(limit)
    .offset(offset);

  return c.json(
    rows.map((r) => {
      const serialized = serializeBigints(r);
      if (!includeBitmap) delete serialized.transformBitmap;
      return serialized;
    }),
  );
});

app.get("/transforms/:tokenId/latest", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));

  const [row] = await db
    .select()
    .from(schema.pixelTransform)
    .where(eq(schema.pixelTransform.tokenId, tokenId))
    .orderBy(desc(schema.pixelTransform.blockNumber))
    .limit(1);

  if (!row) return c.json({ error: "No transforms found for this token" }, 404);

  return c.json(serializeBigints(row));
});

app.get("/transforms/:tokenId/:index", async (c) => {
  const tokenId = BigInt(c.req.param("tokenId"));
  const index = Number(c.req.param("index"));

  const [row] = await db
    .select()
    .from(schema.pixelTransform)
    .where(eq(schema.pixelTransform.tokenId, tokenId))
    .orderBy(asc(schema.pixelTransform.blockNumber))
    .limit(1)
    .offset(index);

  if (!row) return c.json({ error: `Transform version ${index} not found` }, 404);

  return c.json({ ...serializeBigints(row), version: index });
});

// ──────────────────────────────────────────────
//  Activity
// ──────────────────────────────────────────────

app.get("/activity/address/:address", async (c) => {
  const address = c.req.param("address").toLowerCase() as `0x${string}`;
  const { limit, offset } = parsePagination(c);

  const [burns, transforms] = await Promise.all([
    db
      .select()
      .from(schema.burnCommitment)
      .where(eq(schema.burnCommitment.owner, address)),
    db
      .select()
      .from(schema.pixelTransform)
      .where(eq(schema.pixelTransform.transformer, address)),
  ]);

  type ActivityEvent = { type: "burn" | "transform"; blockNumber: string; [key: string]: unknown };
  const events: ActivityEvent[] = [
    ...burns.map((b) => {
      const s = serializeBigints(b);
      return { type: "burn" as const, ...s, blockNumber: String(s.blockNumber) };
    }),
    ...transforms.map((t) => {
      const s = serializeBigints(t);
      delete s.transformBitmap;
      return { type: "transform" as const, ...s, blockNumber: String(s.blockNumber) };
    }),
  ].sort((a, b) => Number(BigInt(b.blockNumber) - BigInt(a.blockNumber)));

  return c.json(events.slice(offset, offset + limit));
});

// ──────────────────────────────────────────────
//  Stats
// ──────────────────────────────────────────────

app.get("/stats", async (c) => {
  const [burnCommitmentCount] = await db
    .select({ count: count() })
    .from(schema.burnCommitment);

  const [burnedTokenCount] = await db
    .select({ count: count() })
    .from(schema.burnedToken);

  const [transformCount] = await db
    .select({ count: count() })
    .from(schema.pixelTransform);

  const [tokenDataCount] = await db
    .select({ count: count() })
    .from(schema.tokenData);

  const [zombieTokenCount] = await db
    .select({ count: count() })
    .from(schema.zombieTokenState)
    .where(eq(schema.zombieTokenState.isZombie, true));

  const [legendaryCanvasCount] = await db
    .select({ count: count() })
    .from(schema.legendaryCanvasTrait)
    .where(eq(schema.legendaryCanvasTrait.isLegendary, true));

  const [actionPointsSum] = await db
    .select({ total: sum(schema.burnCommitment.totalActions) })
    .from(schema.burnCommitment)
    .where(eq(schema.burnCommitment.revealed, true));

  return c.json({
    totalBurnCommitments: burnCommitmentCount?.count ?? 0,
    totalBurnedTokens: burnedTokenCount?.count ?? 0,
    totalTransforms: transformCount?.count ?? 0,
    totalTokenData: tokenDataCount?.count ?? 0,
    totalZombies: zombieTokenCount?.count ?? 0,
    totalLegendaryCanvases: legendaryCanvasCount?.count ?? 0,
    totalActionPointsDistributed: (actionPointsSum?.total ?? "0").toString(),
  });
});

// ──────────────────────────────────────────────
//  Rarity Snapshot
// ──────────────────────────────────────────────

app.get("/rarity/snapshot", async (c) => {
  const tokenContractRaw = c.req.query("tokenContract");
  const tokenContract = tokenContractRaw
    ? (tokenContractRaw.toLowerCase() as `0x${string}`)
    : undefined;

  const [
    tokenRows,
    ownerRows,
    canvasRows,
    zombieRows,
    legendaryCanvasRows,
    burnedRows,
    commitmentRows,
  ] = await Promise.all([
    db.select().from(schema.tokenData).orderBy(asc(schema.tokenData.tokenId)),
    db.select().from(schema.normieOwner),
    db.select().from(schema.canvasTokenState),
    db.select().from(schema.zombieTokenState),
    db.select().from(schema.legendaryCanvasTrait),
    db.select().from(schema.burnedToken),
    db.select().from(schema.burnCommitment),
  ]);

  const agentRows = tokenContract
    ? await db
        .select()
        .from(schema.agentBinding)
        .where(eq(schema.agentBinding.tokenContract, tokenContract))
    : await db.select().from(schema.agentBinding);

  const owners = new Map<bigint, `0x${string}`>();
  for (const row of ownerRows) owners.set(row.tokenId, row.owner);

  const canvasStates = new Map<string, Record<string, unknown>>();
  for (const row of canvasRows) {
    canvasStates.set(row.tokenId.toString(), serializeBigints(row));
  }

  const zombieStates = new Map<string, Record<string, unknown>>();
  for (const row of zombieRows) {
    zombieStates.set(row.tokenId.toString(), serializeBigints(row));
  }

  const legendaryCanvasStates = new Map<string, Record<string, unknown>>();
  for (const row of legendaryCanvasRows) {
    legendaryCanvasStates.set(row.tokenId.toString(), serializeBigints(row));
  }

  const { directCounts, recursiveCounts } = buildBurnSummaries(commitmentRows, burnedRows);

  const byWallet = new Map<string, {
    wallet: string;
    customizedTokensHeld: number;
    totalRecursiveBurnCount: number;
    totalDirectBurnCount: number;
    tokenIds: number[];
  }>();

  for (const [tokenId, recursiveBurnCount] of recursiveCounts) {
    if (recursiveBurnCount <= 0) continue;
    const owner = owners.get(tokenId);
    if (!owner) continue;

    const wallet = owner.toLowerCase();
    const existing = byWallet.get(wallet) ?? {
      wallet,
      customizedTokensHeld: 0,
      totalRecursiveBurnCount: 0,
      totalDirectBurnCount: 0,
      tokenIds: [],
    };
    existing.customizedTokensHeld += 1;
    existing.totalRecursiveBurnCount += recursiveBurnCount;
    existing.totalDirectBurnCount += directCounts.get(tokenId) ?? 0;
    existing.tokenIds.push(Number(tokenId));
    byWallet.set(wallet, existing);
  }

  const recursiveBurnHolders = [...byWallet.values()]
    .map((wallet) => ({
      ...wallet,
      tokenIds: wallet.tokenIds.sort((a, b) => a - b),
    }))
    .sort((a, b) =>
      b.totalRecursiveBurnCount - a.totalRecursiveBurnCount ||
      b.customizedTokensHeld - a.customizedTokensHeld,
    );

  const tokens = tokenRows.map((row) => {
    const tokenId = row.tokenId.toString();
    return {
      ...serializeBigints(row),
      owner: owners.get(row.tokenId)?.toLowerCase() ?? null,
      canvas: canvasStates.get(tokenId) ?? null,
      zombie: zombieStates.get(tokenId) ?? null,
      legendaryCanvas: legendaryCanvasStates.get(tokenId) ?? null,
    };
  });

  return c.json({
    tokens,
    burnedTokenIds: burnedRows.map((row) => row.tokenId.toString()),
    burnCounts: {
      direct: numberMapToRecord(directCounts),
      recursive: numberMapToRecord(recursiveCounts),
    },
    recursiveBurnHolders: {
      wallets: recursiveBurnHolders,
    },
    agentBindings: agentRows.map(serializeBigints),
    stats: {
      totalTokenData: tokenRows.length,
      totalOwners: ownerRows.length,
      totalBurnedTokens: burnedRows.length,
      totalBurnCommitments: commitmentRows.length,
      totalAgentBindings: agentRows.length,
    },
  });
});

app.get("/rarity/snapshot/block/:blockNumber", async (c) => {
  const blockNumber = parseBlockNumberParam(c.req.param("blockNumber"));
  if (blockNumber === null) return c.json({ error: "Invalid blockNumber" }, 400);

  const tokenContractRaw = c.req.query("tokenContract");
  const tokenContract = tokenContractRaw
    ? (tokenContractRaw.toLowerCase() as `0x${string}`)
    : undefined;

  return c.json(await buildHistoricalRaritySnapshot(blockNumber, tokenContract));
});

async function buildHistoricalRaritySnapshot(
  blockNumber: bigint,
  tokenContract?: `0x${string}`,
) {
  const [
    tokenRows,
    transferRows,
    transformRows,
    burnedRows,
    commitmentRows,
    zombieCommitmentRows,
    zombiePoolRows,
    legendaryCanvasEventRows,
  ] = await Promise.all([
    db
      .select()
      .from(schema.tokenData)
      .where(lte(schema.tokenData.blockNumber, blockNumber))
      .orderBy(asc(schema.tokenData.tokenId)),
    db
      .select()
      .from(schema.normieTransfer)
      .where(lte(schema.normieTransfer.blockNumber, blockNumber))
      .orderBy(asc(schema.normieTransfer.blockNumber), asc(schema.normieTransfer.logIndex)),
    db
      .select()
      .from(schema.pixelTransform)
      .where(lte(schema.pixelTransform.blockNumber, blockNumber)),
    db
      .select()
      .from(schema.burnedToken)
      .where(lte(schema.burnedToken.blockNumber, blockNumber)),
    db
      .select()
      .from(schema.burnCommitment)
      .where(lte(schema.burnCommitment.blockNumber, blockNumber)),
    db
      .select()
      .from(schema.zombieCommitment)
      .where(lte(schema.zombieCommitment.blockNumber, blockNumber)),
    db.select().from(schema.zombiePoolItem),
    db
      .select()
      .from(schema.legendaryCanvasTraitEvent)
      .where(lte(schema.legendaryCanvasTraitEvent.blockNumber, blockNumber)),
  ]);

  const agentRows = tokenContract
    ? await db
        .select()
        .from(schema.agentBinding)
        .where(
          and(
            eq(schema.agentBinding.tokenContract, tokenContract),
            lte(schema.agentBinding.blockNumber, blockNumber),
          ),
        )
    : await db
        .select()
        .from(schema.agentBinding)
        .where(lte(schema.agentBinding.blockNumber, blockNumber));

  const owners = buildHistoricalOwners(transferRows);
  const { states: canvasStates, pixelCounts } = buildHistoricalCanvasStates(
    blockNumber,
    tokenRows,
    transformRows,
    commitmentRows,
  );
  const zombieStates = buildHistoricalZombieStates(blockNumber, zombieCommitmentRows, zombiePoolRows);
  const legendaryCanvasStates = buildHistoricalLegendaryCanvasStates(legendaryCanvasEventRows);
  const { directCounts, recursiveCounts } = buildBurnSummaries(commitmentRows, burnedRows);

  const burnedIds = new Set<bigint>();
  for (const row of burnedRows) burnedIds.add(row.tokenId);
  for (const row of transferRows) {
    if (row.to.toLowerCase() === ZERO_ADDRESS) burnedIds.add(row.tokenId);
  }

  const byWallet = new Map<string, {
    wallet: string;
    customizedTokensHeld: number;
    totalRecursiveBurnCount: number;
    totalDirectBurnCount: number;
    tokenIds: number[];
  }>();

  for (const [tokenId, recursiveBurnCount] of recursiveCounts) {
    if (recursiveBurnCount <= 0) continue;
    const owner = owners.get(tokenId);
    if (!owner) continue;

    const wallet = owner.toLowerCase();
    const existing = byWallet.get(wallet) ?? {
      wallet,
      customizedTokensHeld: 0,
      totalRecursiveBurnCount: 0,
      totalDirectBurnCount: 0,
      tokenIds: [],
    };
    existing.customizedTokensHeld += 1;
    existing.totalRecursiveBurnCount += recursiveBurnCount;
    existing.totalDirectBurnCount += directCounts.get(tokenId) ?? 0;
    existing.tokenIds.push(Number(tokenId));
    byWallet.set(wallet, existing);
  }

  const recursiveBurnHolders = [...byWallet.values()]
    .map((wallet) => ({
      ...wallet,
      tokenIds: wallet.tokenIds.sort((a, b) => a - b),
    }))
    .sort((a, b) =>
      b.totalRecursiveBurnCount - a.totalRecursiveBurnCount ||
      b.customizedTokensHeld - a.customizedTokensHeld,
    );

  const tokens = tokenRows.map((row) => {
    const tokenId = row.tokenId.toString();
    return {
      ...serializeBigints(row),
      owner: owners.get(row.tokenId)?.toLowerCase() ?? null,
      canvas: canvasStates.get(tokenId) ?? null,
      zombie: zombieStates.get(tokenId) ?? null,
      legendaryCanvas: legendaryCanvasStates.get(tokenId) ?? null,
      displayPixelCount: pixelCounts.get(tokenId) ?? null,
    };
  });

  return {
    blockNumber: blockNumber.toString(),
    historical: true,
    tokens,
    burnedTokenIds: [...burnedIds].map((id) => id.toString()).sort((a, b) => Number(a) - Number(b)),
    burnCounts: {
      direct: numberMapToRecord(directCounts),
      recursive: numberMapToRecord(recursiveCounts),
    },
    recursiveBurnHolders: {
      wallets: recursiveBurnHolders,
    },
    agentBindings: agentRows.map(serializeBigints),
    stats: {
      totalTokenData: tokenRows.length,
      totalOwners: owners.size,
      totalBurnedTokens: burnedIds.size,
      totalBurnCommitments: commitmentRows.length,
      totalAgentBindings: agentRows.length,
    },
  };
}

// ──────────────────────────────────────────────
//  Adapter8004: Agent Bindings
// ──────────────────────────────────────────────

// Single-token lookup: (tokenContract, tokenId) → binding | null
app.get("/agent-binding/:tokenContract/:tokenId", async (c) => {
  const tokenContract = c.req.param("tokenContract").toLowerCase() as `0x${string}`;
  let tokenId: bigint;
  try {
    tokenId = BigInt(c.req.param("tokenId"));
  } catch {
    return c.json({ error: "Invalid tokenId" }, 400);
  }

  const [row] = await db
    .select()
    .from(schema.agentBinding)
    .where(
      and(
        eq(schema.agentBinding.tokenContract, tokenContract),
        eq(schema.agentBinding.tokenId, tokenId),
      ),
    )
    .limit(1);

  if (!row) return c.json({ binding: null });
  return c.json({ binding: serializeBigints(row) });
});

// Batch lookup: POST { tokenContract, tokenIds[] } → { [tokenId]: binding }
// Cap at 1000 ids per request.
app.post("/agent-binding/batch", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    tokenContract?: string;
    tokenIds?: (string | number)[];
  };
  if (!body.tokenContract || !Array.isArray(body.tokenIds) || body.tokenIds.length === 0) {
    return c.json({ bindings: {} });
  }
  const tokenContract = body.tokenContract.toLowerCase() as `0x${string}`;
  const ids = new Set<bigint>();
  for (const raw of body.tokenIds.slice(0, 1000)) {
    try {
      ids.add(BigInt(raw));
    } catch {
      // skip malformed
    }
  }
  if (ids.size === 0) return c.json({ bindings: {} });

  const rows = await db
    .select()
    .from(schema.agentBinding)
    .where(
      and(
        eq(schema.agentBinding.tokenContract, tokenContract),
        inArray(schema.agentBinding.tokenId, Array.from(ids)),
      ),
    );

  const bindings: Record<string, unknown> = {};
  for (const r of rows) {
    bindings[r.tokenId.toString()] = serializeBigints(r);
  }
  return c.json({ bindings });
});

// List bindings.
//
//   GET /agent-bindings?limit=N&sort=desc|asc&tokenContract=0x...
//                     &cursor=<agentId>        (excludes the cursor row)
//                     &offset=N                (used only when cursor absent)
//
// Default sort is `desc` (newest agentId first). When `cursor` is supplied the
// next page returns rows on the far side of the cursor in the sort direction
// — `agentId < cursor` for desc, `agentId > cursor` for asc — which keeps
// pagination correct under concurrent inserts without an N+1 offset scan.
app.get("/agent-bindings", async (c) => {
  const { limit, offset } = parsePagination(c);
  const tokenContractRaw = c.req.query("tokenContract");
  const tokenContract = tokenContractRaw
    ? (tokenContractRaw.toLowerCase() as `0x${string}`)
    : undefined;
  const sort = c.req.query("sort") === "asc" ? "asc" : "desc";
  const cursorRaw = c.req.query("cursor");
  let cursor: bigint | undefined;
  if (cursorRaw) {
    try {
      cursor = BigInt(cursorRaw);
    } catch {
      return c.json({ error: "`cursor` must be an integer string" }, 400);
    }
  }

  const conds = [];
  if (tokenContract) conds.push(eq(schema.agentBinding.tokenContract, tokenContract));
  if (cursor !== undefined) {
    conds.push(
      sort === "asc"
        ? gt(schema.agentBinding.agentId, cursor)
        : lt(schema.agentBinding.agentId, cursor),
    );
  }
  const whereClause = conds.length === 0 ? undefined : conds.length === 1 ? conds[0] : and(...conds);
  const orderBy = sort === "asc"
    ? asc(schema.agentBinding.agentId)
    : desc(schema.agentBinding.agentId);

  // Drizzle's chain narrows the return type with each call, so we build the
  // full query inline rather than mutating `let query` (which fails type
  // narrowing). Cursor pagination skips offset; without a cursor we fall back
  // to offset paging for backwards compatibility with the reconciler sweep.
  const rows = cursor === undefined
    ? whereClause
      ? await db
          .select()
          .from(schema.agentBinding)
          .where(whereClause)
          .orderBy(orderBy)
          .limit(limit)
          .offset(offset)
      : await db
          .select()
          .from(schema.agentBinding)
          .orderBy(orderBy)
          .limit(limit)
          .offset(offset)
    : whereClause
      ? await db
          .select()
          .from(schema.agentBinding)
          .where(whereClause)
          .orderBy(orderBy)
          .limit(limit)
      : await db
          .select()
          .from(schema.agentBinding)
          .orderBy(orderBy)
          .limit(limit);

  return c.json({
    bindings: rows.map(serializeBigints),
    hasMore: rows.length === limit,
  });
});

// Cheap count of bindings, optionally filtered by tokenContract. Used by the
// gallery header. Lives next to the list endpoint so a future enrichment can
// fold it into the list response if we want to save a round trip.
app.get("/agent-bindings/count", async (c) => {
  const tokenContractRaw = c.req.query("tokenContract");
  const tokenContract = tokenContractRaw
    ? (tokenContractRaw.toLowerCase() as `0x${string}`)
    : undefined;

  const [row] = tokenContract
    ? await db
        .select({ total: count() })
        .from(schema.agentBinding)
        .where(eq(schema.agentBinding.tokenContract, tokenContract))
    : await db.select({ total: count() }).from(schema.agentBinding);
  return c.json({ count: row?.total ?? 0 });
});

// Agent lookup: agentId → binding | null
app.get("/agent/:agentId", async (c) => {
  let agentId: bigint;
  try {
    agentId = BigInt(c.req.param("agentId"));
  } catch {
    return c.json({ error: "Invalid agentId" }, 400);
  }

  const [row] = await db
    .select()
    .from(schema.agentBinding)
    .where(eq(schema.agentBinding.agentId, agentId))
    .limit(1);

  if (!row) return c.json({ binding: null });
  return c.json({ binding: serializeBigints(row) });
});

export default app;

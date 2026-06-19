import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { eq, desc, count, sum, asc, and, gt, lt, inArray } from "ponder";

const app = new Hono();

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

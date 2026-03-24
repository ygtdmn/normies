import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { eq, desc, count, sum, asc } from "ponder";

const app = new Hono();

// ──────────────────────────────────────────────
//  Helpers
// ──────────────────────────────────────────────

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
  const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50), 1), 100);
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

  const [actionPointsSum] = await db
    .select({ total: sum(schema.burnCommitment.totalActions) })
    .from(schema.burnCommitment)
    .where(eq(schema.burnCommitment.revealed, true));

  return c.json({
    totalBurnCommitments: burnCommitmentCount?.count ?? 0,
    totalBurnedTokens: burnedTokenCount?.count ?? 0,
    totalTransforms: transformCount?.count ?? 0,
    totalActionPointsDistributed: (actionPointsSum?.total ?? "0").toString(),
  });
});

export default app;

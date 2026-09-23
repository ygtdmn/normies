import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { and, asc, desc, eq, gt } from "ponder";

// ──────────────────────────────────────────────
//  Revenue share read API: epochs, claims, totals, and the state snapshot the
//  API server scores wallets from. Mounted at the root (see ./index.ts).
// ──────────────────────────────────────────────

const app = new Hono();
const GLOBAL_ID = "global";

function serializeBigints<T extends Record<string, unknown>>(row: T): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) {
    result[key] = typeof value === "bigint" ? value.toString() : value;
  }
  return result;
}

function isAddress(value: string): boolean {
  return /^0x[0-9a-fA-F]{40}$/.test(value);
}

app.get("/revshare/epochs", async (c) => {
  const rows = await db.select().from(schema.revshareEpoch).orderBy(desc(schema.revshareEpoch.epochId)).limit(100);
  return c.json({ epochs: rows.map(serializeBigints) });
});

app.get("/revshare/epochs/:id", async (c) => {
  let epochId: bigint;
  try {
    epochId = BigInt(c.req.param("id"));
  } catch {
    return c.json({ error: "Invalid epoch id" }, 400);
  }
  const [row] = await db.select().from(schema.revshareEpoch).where(eq(schema.revshareEpoch.epochId, epochId)).limit(1);
  if (!row) return c.json({ error: "Epoch not found" }, 404);
  return c.json(serializeBigints(row));
});

app.get("/revshare/claims/:address", async (c) => {
  const address = c.req.param("address").toLowerCase();
  if (!isAddress(address)) return c.json({ error: "Invalid address" }, 400);
  const rows = await db
    .select()
    .from(schema.revshareClaim)
    .where(eq(schema.revshareClaim.account, address as `0x${string}`))
    .orderBy(desc(schema.revshareClaim.epochId));
  return c.json({ claims: rows.map(serializeBigints) });
});

app.get("/revshare/stats", async (c) => {
  const [row] = await db.select().from(schema.revshareStats).where(eq(schema.revshareStats.id, GLOBAL_ID)).limit(1);
  return c.json(
    row
      ? serializeBigints(row)
      : { epochs: 0, allocatedWei: "0", claimedWei: "0", sweptWei: "0", royaltiesToPoolWei: "0", blockNumber: null, timestamp: null },
  );
});

/**
 * Everything the score reads, in one compact payload: who holds which Normie, the pixels on each (only tokens that
 * carry any), loose balances and active listings. The API server caches it and scores every wallet from it. Epoch
 * payouts are NOT computed from this: those come from RPC state at the sampled blocks.
 */
app.get("/revshare/state", async (c) => {
  const [owners, tokens, balances, listings] = await Promise.all([
    db.select().from(schema.normieOwner).orderBy(asc(schema.normieOwner.tokenId)),
    db
      .select({
        tokenId: schema.canvasTokenState.tokenId,
        actionPoints: schema.canvasTokenState.actionPoints,
      })
      .from(schema.canvasTokenState)
      .where(gt(schema.canvasTokenState.actionPoints, 0n)),
    db
      .select({ address: schema.pixelBalance.address, balance: schema.pixelBalance.balance })
      .from(schema.pixelBalance)
      .where(gt(schema.pixelBalance.balance, 0n)),
    db
      .select({ seller: schema.marketListing.seller, remaining: schema.marketListing.remaining })
      .from(schema.marketListing)
      .where(and(eq(schema.marketListing.status, "active"), gt(schema.marketListing.remaining, 0))),
  ]);
  return c.json({
    owners: owners.map((o) => [o.tokenId.toString(), o.owner]),
    tokens: tokens.map((t) => [t.tokenId.toString(), t.actionPoints.toString()]),
    balances: balances.map((b) => [b.address, b.balance.toString()]),
    listings: listings.map((l) => [l.seller, l.remaining]),
  });
});

export default app;

import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { ownKey, queryInt } from "./query.js";
import { eq, desc, asc, and, or, gt, lt, lte, count, inArray } from "ponder";

// ──────────────────────────────────────────────
//  Pixel Market read API: ledger balances, listings, fills, stats, sinks.
//  Mounted at the root of the indexer API (see ./index.ts).
// ──────────────────────────────────────────────

const app = new Hono();
const GLOBAL_ID = "global";
const INTERVALS = { "1h": 3600, "4h": 14_400, "1d": 86_400 } as const;

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
  const limit = queryInt(c.req.query("limit"), 50, 1, 100);
  const offset = queryInt(c.req.query("offset"), 0, 0);
  return { limit, offset };
}

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

function parseBigint(raw: string | undefined): bigint | undefined {
  if (raw === undefined) return undefined;
  try {
    const v = BigInt(raw);
    return v < 0n ? undefined : v;
  } catch {
    return undefined;
  }
}

function serializeTokenPixels(row: {
  tokenId: bigint;
  actionPoints: bigint;
  lockedPixels: number;
  gridSize: number;
  baseCleared: boolean;
  migrated: boolean;
  customized: boolean;
  blockNumber: bigint;
}) {
  const attached = row.actionPoints;
  const locked = BigInt(row.lockedPixels);
  return {
    tokenId: row.tokenId.toString(),
    attached: attached.toString(),
    locked: locked.toString(),
    free: (attached > locked ? attached - locked : 0n).toString(),
    gridSize: row.gridSize,
    baseCleared: row.baseCleared,
    migrated: row.migrated,
    customized: row.customized,
    blockNumber: row.blockNumber.toString(),
  };
}

// ──────────────────────────────────────────────
//  Pixels (ledger)
// ──────────────────────────────────────────────

app.get("/pixels/balance/:address", async (c) => {
  const address = c.req.param("address").toLowerCase();
  if (!isAddress(address)) return c.json({ error: "Invalid Ethereum address" }, 400);

  const [row] = await db
    .select()
    .from(schema.pixelBalance)
    .where(eq(schema.pixelBalance.address, address as `0x${string}`))
    .limit(1);

  return c.json({
    address,
    balance: (row?.balance ?? 0n).toString(),
    updatedBlock: row?.updatedBlock?.toString() ?? null,
  });
});

/**
 * Holders of #PIXEL outside Normies, largest first. Pixels in an open listing still belong to the seller, so the
 * market's escrow is credited back to each seller (`listed`) and the market contract itself is left out. `balance` is
 * `wallet + listed`, so the shares still add up to every #PIXEL held in wallets.
 */
const MARKET = (process.env.PONDER_MARKET_ADDRESS ?? "").toLowerCase();

async function rankedHolders() {
  const [wallets, listings] = await Promise.all([
    db
      .select()
      .from(schema.pixelBalance)
      .where(gt(schema.pixelBalance.balance, 0n)),
    db
      .select({
        seller: schema.marketListing.seller,
        remaining: schema.marketListing.remaining,
        updatedBlockNumber: schema.marketListing.updatedBlockNumber,
      })
      .from(schema.marketListing)
      .where(and(eq(schema.marketListing.status, "active"), gt(schema.marketListing.remaining, 0))),
  ]);

  const byAddress = new Map<string, { wallet: bigint; listed: bigint; updatedBlock: bigint }>();
  const entry = (address: string) => {
    const key = address.toLowerCase();
    let row = byAddress.get(key);
    if (!row) {
      row = { wallet: 0n, listed: 0n, updatedBlock: 0n };
      byAddress.set(key, row);
    }
    return row;
  };
  for (const w of wallets) {
    if (w.address.toLowerCase() === MARKET) continue;
    const row = entry(w.address);
    row.wallet += w.balance;
    if (w.updatedBlock > row.updatedBlock) row.updatedBlock = w.updatedBlock;
  }
  for (const l of listings) {
    const row = entry(l.seller);
    row.listed += BigInt(l.remaining);
    if (l.updatedBlockNumber > row.updatedBlock) row.updatedBlock = l.updatedBlockNumber;
  }

  return [...byAddress.entries()]
    .map(([address, r]) => ({ address, balance: r.wallet + r.listed, wallet: r.wallet, listed: r.listed, updatedBlock: r.updatedBlock }))
    .filter((r) => r.balance > 0n)
    .sort((a, b) => (a.balance === b.balance ? (a.address < b.address ? -1 : 1) : a.balance > b.balance ? -1 : 1));
}

app.get("/pixels/holders", async (c) => {
  const { limit, offset } = parsePagination(c);
  const ranked = await rankedHolders();
  const page = ranked.slice(offset, offset + limit);
  return c.json({ holders: page.map(serializeBigints), hasMore: ranked.length > offset + limit });
});

app.get("/pixels/token/:tokenId", async (c) => {
  const tokenId = parseBigint(c.req.param("tokenId"));
  if (tokenId === undefined) return c.json({ error: "Invalid tokenId" }, 400);

  const [row] = await db
    .select()
    .from(schema.canvasTokenState)
    .where(eq(schema.canvasTokenState.tokenId, tokenId))
    .limit(1);
  if (!row) return c.json({ error: "Canvas state not found" }, 404);

  const [owner] = await db
    .select({ owner: schema.normieOwner.owner })
    .from(schema.normieOwner)
    .where(eq(schema.normieOwner.tokenId, tokenId))
    .limit(1);

  return c.json({ ...serializeTokenPixels(row), owner: owner?.owner ?? null });
});

app.post("/pixels/token/batch", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { tokenIds?: unknown };
  const ids: bigint[] = [];
  if (Array.isArray(body.tokenIds)) {
    for (const value of body.tokenIds.slice(0, 1000)) {
      const parsed = parseBigint(String(value));
      if (parsed !== undefined) ids.push(parsed);
    }
  }
  if (ids.length === 0) return c.json({ tokens: {} });

  const rows = await db
    .select()
    .from(schema.canvasTokenState)
    .where(inArray(schema.canvasTokenState.tokenId, ids));
  const tokens: Record<string, unknown> = {};
  for (const row of rows) tokens[row.tokenId.toString()] = serializeTokenPixels(row);
  return c.json({ tokens });
});

app.get("/pixels/activity/:address", async (c) => {
  const address = c.req.param("address").toLowerCase() as `0x${string}`;
  if (!isAddress(address)) return c.json({ error: "Invalid Ethereum address" }, 400);
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.pixelLedgerEvent)
    .where(or(eq(schema.pixelLedgerEvent.from, address), eq(schema.pixelLedgerEvent.to, address)))
    .orderBy(desc(schema.pixelLedgerEvent.blockNumber), desc(schema.pixelLedgerEvent.logIndex))
    .limit(limit + 1)
    .offset(offset);
  const page = rows.slice(0, limit);
  return c.json({ events: page.map(serializeBigints), hasMore: rows.length > limit });
});

app.get("/pixels/token/:tokenId/activity", async (c) => {
  const tokenId = parseBigint(c.req.param("tokenId"));
  if (tokenId === undefined) return c.json({ error: "Invalid tokenId" }, 400);
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.pixelLedgerEvent)
    .where(eq(schema.pixelLedgerEvent.tokenId, tokenId))
    .orderBy(desc(schema.pixelLedgerEvent.blockNumber), desc(schema.pixelLedgerEvent.logIndex))
    .limit(limit + 1)
    .offset(offset);
  const page = rows.slice(0, limit);
  return c.json({ events: page.map(serializeBigints), hasMore: rows.length > limit });
});

app.get("/pixels/supply", async (c) => {
  const [supply] = await db
    .select()
    .from(schema.pixelSupply)
    .where(eq(schema.pixelSupply.id, GLOBAL_ID))
    .limit(1);
  // Same holders as /pixels/holders: sellers count through their listings, the market contract does not.
  const holders = await rankedHolders();
  return c.json({
    totalWallet: (supply?.totalWallet ?? 0n).toString(),
    totalAttached: (supply?.totalAttached ?? 0n).toString(),
    totalMigrated: supply?.totalMigrated ?? 0,
    wallets: holders.length,
    blockNumber: supply?.blockNumber?.toString() ?? null,
    timestamp: supply?.timestamp?.toString() ?? null,
  });
});

// ──────────────────────────────────────────────
//  Market: listings
// ──────────────────────────────────────────────

const LISTING_SORTS = {
  "price-asc": [asc(schema.marketListing.pricePerPixel), asc(schema.marketListing.listingId)],
  "price-desc": [desc(schema.marketListing.pricePerPixel), asc(schema.marketListing.listingId)],
  "amount-desc": [desc(schema.marketListing.remaining), asc(schema.marketListing.listingId)],
  newest: [desc(schema.marketListing.listingId)],
} as const;

app.get("/market/listings", async (c) => {
  const { limit, offset } = parsePagination(c);
  const statusRaw = c.req.query("status") ?? "active";
  const status = statusRaw === "all" ? undefined : statusRaw;
  if (status && !["active", "filled", "cancelled"].includes(status)) {
    return c.json({ error: "status must be active, filled, cancelled or all" }, 400);
  }
  const sellerRaw = c.req.query("seller")?.toLowerCase();
  if (sellerRaw !== undefined && !isAddress(sellerRaw)) return c.json({ error: "Invalid seller" }, 400);
  const partialRaw = c.req.query("partial");
  const sortRaw = c.req.query("sort") ?? "price-asc";
  if (!ownKey(LISTING_SORTS, sortRaw)) {
    return c.json({ error: `sort must be one of ${Object.keys(LISTING_SORTS).join(", ")}` }, 400);
  }
  const order = LISTING_SORTS[sortRaw];
  const now = BigInt(Math.floor(Date.now() / 1000));
  const includeExpired = c.req.query("expired") === "true";

  const conditions = [];
  if (status) conditions.push(eq(schema.marketListing.status, status));
  if (sellerRaw) conditions.push(eq(schema.marketListing.seller, sellerRaw as `0x${string}`));
  if (partialRaw === "true") conditions.push(eq(schema.marketListing.partialFill, true));
  if (partialRaw === "false") conditions.push(eq(schema.marketListing.partialFill, false));
  if (status === "active" && !includeExpired) {
    conditions.push(or(eq(schema.marketListing.expiry, 0n), gt(schema.marketListing.expiry, now)));
  }

  const query = db.select().from(schema.marketListing);
  const rows = conditions.length > 0
    ? await query.where(and(...conditions)).orderBy(...order).limit(limit + 1).offset(offset)
    : await query.orderBy(...order).limit(limit + 1).offset(offset);
  const page = rows.slice(0, limit);
  return c.json({ listings: page.map(serializeBigints), hasMore: rows.length > limit });
});

app.get("/market/listings/:id", async (c) => {
  const listingId = parseBigint(c.req.param("id"));
  if (listingId === undefined) return c.json({ error: "Invalid listing id" }, 400);

  const [row] = await db
    .select()
    .from(schema.marketListing)
    .where(eq(schema.marketListing.listingId, listingId))
    .limit(1);
  if (!row) return c.json({ error: "Listing not found" }, 404);

  const fills = await db
    .select()
    .from(schema.marketFill)
    .where(eq(schema.marketFill.listingId, listingId))
    .orderBy(asc(schema.marketFill.blockNumber), asc(schema.marketFill.logIndex));

  return c.json({ ...serializeBigints(row), fills: fills.map(serializeBigints) });
});

app.get("/market/depth", async (c) => {
  const now = BigInt(Math.floor(Date.now() / 1000));
  const rows = await db
    .select({
      pricePerPixel: schema.marketListing.pricePerPixel,
      remaining: schema.marketListing.remaining,
      partialFill: schema.marketListing.partialFill,
    })
    .from(schema.marketListing)
    .where(
      and(
        eq(schema.marketListing.status, "active"),
        or(eq(schema.marketListing.expiry, 0n), gt(schema.marketListing.expiry, now)),
      ),
    )
    .orderBy(asc(schema.marketListing.pricePerPixel));

  const levels = new Map<bigint, { remaining: number; listings: number; partialRemaining: number }>();
  for (const row of rows) {
    const level = levels.get(row.pricePerPixel) ?? { remaining: 0, listings: 0, partialRemaining: 0 };
    level.remaining += row.remaining;
    level.listings += 1;
    if (row.partialFill) level.partialRemaining += row.remaining;
    levels.set(row.pricePerPixel, level);
  }
  return c.json({
    levels: Array.from(levels.entries()).map(([price, level]) => ({
      pricePerPixel: price.toString(),
      ...level,
    })),
  });
});

// ──────────────────────────────────────────────
//  Market: fills, stats, candles
// ──────────────────────────────────────────────

app.get("/market/fills", async (c) => {
  const { limit, offset } = parsePagination(c);
  const afterTimestamp = parseBigint(c.req.query("after_timestamp"));
  if (c.req.query("after_timestamp") !== undefined && afterTimestamp === undefined) {
    return c.json({ error: "`after_timestamp` must be a non-negative unix timestamp string" }, 400);
  }
  const sort = c.req.query("sort") === "asc" ? "asc" : "desc";
  const orderBy = sort === "asc"
    ? [asc(schema.marketFill.timestamp), asc(schema.marketFill.blockNumber), asc(schema.marketFill.logIndex)]
    : [desc(schema.marketFill.timestamp), desc(schema.marketFill.blockNumber), desc(schema.marketFill.logIndex)];

  const query = db.select().from(schema.marketFill);
  const rows = afterTimestamp !== undefined
    ? await query.where(gt(schema.marketFill.timestamp, afterTimestamp)).orderBy(...orderBy).limit(limit + 1).offset(offset)
    : await query.orderBy(...orderBy).limit(limit + 1).offset(offset);
  const page = rows.slice(0, limit);
  return c.json({
    fills: page.map(serializeBigints),
    count: page.length,
    hasMore: rows.length > limit,
    afterTimestamp: afterTimestamp?.toString() ?? null,
  });
});

app.get("/market/fills/address/:address", async (c) => {
  const address = c.req.param("address").toLowerCase() as `0x${string}`;
  if (!isAddress(address)) return c.json({ error: "Invalid Ethereum address" }, 400);
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select()
    .from(schema.marketFill)
    .where(or(eq(schema.marketFill.buyer, address), eq(schema.marketFill.seller, address)))
    .orderBy(desc(schema.marketFill.blockNumber), desc(schema.marketFill.logIndex))
    .limit(limit + 1)
    .offset(offset);
  const page = rows.slice(0, limit);
  return c.json({ fills: page.map(serializeBigints), hasMore: rows.length > limit });
});

app.get("/market/stats", async (c) => {
  const now = BigInt(Math.floor(Date.now() / 1000));
  const [stats] = await db
    .select()
    .from(schema.marketStats)
    .where(eq(schema.marketStats.id, GLOBAL_ID))
    .limit(1);
  const active = await db
    .select({ pricePerPixel: schema.marketListing.pricePerPixel, remaining: schema.marketListing.remaining })
    .from(schema.marketListing)
    .where(
      and(
        eq(schema.marketListing.status, "active"),
        or(eq(schema.marketListing.expiry, 0n), gt(schema.marketListing.expiry, now)),
      ),
    );
  const dayAgo = now - 86_400n;
  const recent = await db
    .select({ grossWei: schema.marketFill.grossWei, amount: schema.marketFill.amount, pricePerPixel: schema.marketFill.pricePerPixel, timestamp: schema.marketFill.timestamp })
    .from(schema.marketFill)
    .where(gt(schema.marketFill.timestamp, dayAgo));
  const [last] = await db
    .select({ pricePerPixel: schema.marketFill.pricePerPixel, timestamp: schema.marketFill.timestamp })
    .from(schema.marketFill)
    .orderBy(desc(schema.marketFill.timestamp), desc(schema.marketFill.blockNumber), desc(schema.marketFill.logIndex))
    .limit(1);

  let bestAsk: bigint | null = null;
  let pixelsListed = 0;
  for (const row of active) {
    pixelsListed += row.remaining;
    if (bestAsk === null || row.pricePerPixel < bestAsk) bestAsk = row.pricePerPixel;
  }
  let volume24hWei = 0n;
  let pixels24h = 0;
  for (const row of recent) {
    volume24hWei += row.grossWei;
    pixels24h += row.amount;
  }

  return c.json({
    volumeWei: (stats?.volumeWei ?? 0n).toString(),
    feesWei: (stats?.feesWei ?? 0n).toString(),
    feesCollectedWei: (stats?.feesCollectedWei ?? 0n).toString(),
    pixelsTraded: (stats?.pixelsTraded ?? 0n).toString(),
    fills: stats?.fills ?? 0,
    listings: stats?.listings ?? 0,
    feeBps: stats?.feeBps ?? 1000,
    revenueShareBps: stats?.revenueShareBps ?? 5000,
    paused: stats?.paused ?? true,
    activeListings: active.length,
    pixelsListed,
    bestAskWei: bestAsk?.toString() ?? null,
    lastPriceWei: last?.pricePerPixel.toString() ?? null,
    lastFillTimestamp: last?.timestamp.toString() ?? null,
    volume24hWei: volume24hWei.toString(),
    pixels24h,
    blockNumber: stats?.blockNumber?.toString() ?? null,
    timestamp: stats?.timestamp?.toString() ?? null,
  });
});

// OHLC per bucket in wei per pixel, computed from recent fills. Buckets with no
// fills are omitted; clients carry the previous close forward if they want a
// continuous line.
app.get("/market/candles", async (c) => {
  const intervalKey = c.req.query("interval") ?? "1h";
  if (!ownKey(INTERVALS, intervalKey)) return c.json({ error: "interval must be 1h, 4h or 1d" }, 400);
  const interval = INTERVALS[intervalKey];
  const limit = queryInt(c.req.query("limit"), 168, 1, 1000);
  const now = Math.floor(Date.now() / 1000);
  const since = BigInt(now - interval * limit);

  const rows = await db
    .select({
      pricePerPixel: schema.marketFill.pricePerPixel,
      amount: schema.marketFill.amount,
      grossWei: schema.marketFill.grossWei,
      timestamp: schema.marketFill.timestamp,
      blockNumber: schema.marketFill.blockNumber,
      logIndex: schema.marketFill.logIndex,
    })
    .from(schema.marketFill)
    .where(gt(schema.marketFill.timestamp, since))
    .orderBy(asc(schema.marketFill.timestamp), asc(schema.marketFill.blockNumber), asc(schema.marketFill.logIndex));

  type Candle = { time: number; open: bigint; high: bigint; low: bigint; close: bigint; volumeWei: bigint; pixels: number; fills: number };
  const candles: Candle[] = [];
  for (const row of rows) {
    const time = Math.floor(Number(row.timestamp) / interval) * interval;
    const price = row.pricePerPixel;
    const last = candles[candles.length - 1];
    if (last && last.time === time) {
      if (price > last.high) last.high = price;
      if (price < last.low) last.low = price;
      last.close = price;
      last.volumeWei += row.grossWei;
      last.pixels += row.amount;
      last.fills += 1;
    } else {
      candles.push({ time, open: price, high: price, low: price, close: price, volumeWei: row.grossWei, pixels: row.amount, fills: 1 });
    }
  }
  return c.json({
    interval: intervalKey,
    candles: candles.map((k) => ({
      time: k.time,
      open: k.open.toString(),
      high: k.high.toString(),
      low: k.low.toString(),
      close: k.close.toString(),
      volumeWei: k.volumeWei.toString(),
      pixels: k.pixels,
      fills: k.fills,
    })),
  });
});

// ──────────────────────────────────────────────
//  Canvas sinks and original-canvas commitments
// ──────────────────────────────────────────────

app.get("/canvas/sinks", async (c) => {
  const { limit, offset } = parsePagination(c);
  const tokenId = parseBigint(c.req.query("tokenId"));
  const kind = c.req.query("kind");
  const conditions = [];
  if (tokenId !== undefined) conditions.push(eq(schema.canvasSinkEvent.tokenId, tokenId));
  if (kind === "enlarge" || kind === "clearBase") conditions.push(eq(schema.canvasSinkEvent.kind, kind));

  const query = db.select().from(schema.canvasSinkEvent);
  const rows = conditions.length > 0
    ? await query.where(and(...conditions)).orderBy(desc(schema.canvasSinkEvent.blockNumber)).limit(limit + 1).offset(offset)
    : await query.orderBy(desc(schema.canvasSinkEvent.blockNumber)).limit(limit + 1).offset(offset);
  const page = rows.slice(0, limit);
  return c.json({ events: page.map(serializeBigints), hasMore: rows.length > limit });
});

// Original-canvas commitments not yet revealed there. Every one of them has to be revealed (permissionless)
// before that canvas is paused for the cutover: nothing else can claim them afterwards.
app.get("/burns/pending/legacy", async (c) => {
  const { limit, offset } = parsePagination(c);
  const ownerRaw = c.req.query("owner")?.toLowerCase();
  const conditions = [
    eq(schema.burnCommitment.contractVersion, 1),
    eq(schema.burnCommitment.revealed, false),
  ];
  if (ownerRaw) {
    if (!isAddress(ownerRaw)) return c.json({ error: "Invalid owner" }, 400);
    conditions.push(eq(schema.burnCommitment.owner, ownerRaw as `0x${string}`));
  }
  const rows = await db
    .select()
    .from(schema.burnCommitment)
    .where(and(...conditions))
    .orderBy(asc(schema.burnCommitment.commitId))
    .limit(limit + 1)
    .offset(offset);
  const page = rows.slice(0, limit);
  return c.json({ commitments: page.map(serializeBigints), hasMore: rows.length > limit });
});

// Unused-import guard for operators kept for future filters.
void lt;
void lte;

export default app;

import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { and, asc, desc, eq, gt, inArray, isNotNull } from "ponder";
import { ownKey, queryInt } from "./query.js";

// ──────────────────────────────────────────────
//  Normies Arena read API (v3): status, rounds and their players, registered Normies, Normie and holder state,
//  activity, skins and records. Mounted at the root of the indexer API (see ./index.ts). Everything comes from
//  NormiesArenaStorage events; rows with source "v2" are history from the retired v2 storage.
// ──────────────────────────────────────────────

const app = new Hono();
const GLOBAL_ID = "global";
const ZERO = "0x0000000000000000000000000000000000000000";
const DEAD = "0x000000000000000000000000000000000000dead";
const ID_BOUND = 10_000n;

const STATE_ACTIVE = 1;
const STATE_SHORT = 2;
/** NormiesArenaStorage STATE_* by code. */
const STATE_NAMES = ["unregistered", "active", "short", "cleared"] as const;

type RoundRow = typeof schema.arenaRound.$inferSelect;
type NormieRow = typeof schema.arenaNormie.$inferSelect;
type PlayerRow = typeof schema.arenaRoundPlayer.$inferSelect;
type Query = { req: { query: (key: string) => string | undefined } };

function parsePagination(c: Query, fallback = 50, max = 100) {
  const limit = queryInt(c.req.query("limit"), fallback, 1, max);
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

function parseTokenId(raw: string): bigint | undefined {
  if (!/^\d{1,5}$/.test(raw)) return undefined;
  const id = BigInt(raw);
  return id < ID_BOUND ? id : undefined;
}

function parseRound(raw: string | undefined): number | undefined {
  if (raw === undefined || !/^\d{1,9}$/.test(raw)) return undefined;
  const round = Number(raw);
  return round > 0 ? round : undefined;
}

function stateName(code: number): string {
  return STATE_NAMES[code] ?? "unregistered";
}

/** "upcoming" (sponsored, not started) | "open" | "ended" | "cancelled". */
function roundStatus(r: Pick<RoundRow, "started" | "ended" | "cancelled">): string {
  if (r.cancelled) return "cancelled";
  if (r.ended) return "ended";
  return r.started ? "open" : "upcoming";
}

function serializeRound(r: RoundRow) {
  return {
    ...serializeBigints(r),
    status: roundStatus(r),
    // The storage's poolOf: sponsorship plus entry fees.
    pool: (r.sponsorship + r.fees).toString(),
  };
}

/** The holder a burned Normie reports: the zero address, or the dead address the Arena also counts as burned. */
function isBurnedOwner(owner: string | null | undefined): boolean {
  if (!owner) return false;
  const o = owner.toLowerCase();
  return o === ZERO || o === DEAD;
}

function serializeNormie(n: NormieRow, owner: string | null) {
  return {
    ...serializeBigints(n),
    state: stateName(n.state),
    stateCode: n.state,
    registered: n.state === STATE_ACTIVE || n.state === STATE_SHORT,
    owner,
    burned: isBurnedOwner(owner),
  };
}

function serializePlayer(p: PlayerRow, owner: string | null) {
  return {
    tokenId: p.tokenId.toString(),
    played: p.played,
    charged: p.charged.toString(),
    payoutOrder: p.payoutOrder,
    prize: p.prize?.toString() ?? null,
    refund: p.refund?.toString() ?? null,
    owner,
    blockNumber: p.blockNumber.toString(),
    timestamp: p.timestamp.toString(),
    txHash: p.txHash,
  };
}

async function ownersOf(tokenIds: bigint[]): Promise<Map<string, string>> {
  const owners = new Map<string, string>();
  if (tokenIds.length === 0) return owners;
  const rows = await db
    .select()
    .from(schema.normieOwner)
    .where(inArray(schema.normieOwner.tokenId, tokenIds));
  for (const row of rows) owners.set(row.tokenId.toString(), row.owner);
  return owners;
}

async function getStats() {
  const [row] = await db.select().from(schema.arenaStats).where(eq(schema.arenaStats.id, GLOBAL_ID)).limit(1);
  return row;
}

async function getRound(round: number): Promise<RoundRow | undefined> {
  const [row] = await db.select().from(schema.arenaRound).where(eq(schema.arenaRound.round, round)).limit(1);
  return row;
}

// ──────────────────────────────────────────────
//  Status
// ──────────────────────────────────────────────

app.get("/arena/status", async (c) => {
  const stats = await getStats();
  const current = stats && stats.currentRound > 0 ? await getRound(stats.currentRound) : undefined;
  // Rounds sponsored ahead of time (a rolled pool lands on the next round before it starts).
  const upcoming = await db
    .select()
    .from(schema.arenaRound)
    .where(eq(schema.arenaRound.started, false))
    .orderBy(asc(schema.arenaRound.round));
  const active = stats?.activeCount ?? 0;
  const short = stats?.shortCount ?? 0;

  return c.json({
    indexed: Boolean(process.env.PONDER_ARENA_V3_STORAGE_ADDRESS),
    storage: process.env.PONDER_ARENA_V3_STORAGE_ADDRESS?.toLowerCase() ?? null,
    legacyStorage: process.env.PONDER_ARENA_V2_STORAGE_ADDRESS?.toLowerCase() ?? null,
    currentRound: stats?.currentRound ?? 0,
    currentFree: stats?.currentFree ?? false,
    cumulative: (stats?.cumulative ?? 0n).toString(),
    // The current round while it is open, else null.
    openRound: current && roundStatus(current) === "open" ? current.round : null,
    round: current ? serializeRound(current) : null,
    upcoming: upcoming.map(serializeRound),
    normies: {
      registered: active + short,
      active,
      short,
      cleared: stats?.clearedCount ?? 0,
    },
    totals: {
      balances: (stats?.totalAllocated ?? 0n).toString(),
      pools: (stats?.totalPooled ?? 0n).toString(),
      roundsStarted: stats?.roundsStarted ?? 0,
      roundsEnded: stats?.roundsEnded ?? 0,
      roundsCancelled: stats?.roundsCancelled ?? 0,
      playerEntries: stats?.playerEntries ?? 0,
      pixelsCharged: (stats?.pixelsCharged ?? 0n).toString(),
      prizes: (stats?.prizes ?? 0n).toString(),
      refunds: (stats?.refunds ?? 0n).toString(),
      pixelsSponsored: (stats?.pixelsSponsored ?? 0n).toString(),
      pixelsDeposited: (stats?.pixelsDeposited ?? 0n).toString(),
      pixelsWithdrawn: (stats?.pixelsWithdrawn ?? 0n).toString(),
      pixelsRescued: (stats?.pixelsRescued ?? 0n).toString(),
      balancesMigrated: (stats?.balancesMigrated ?? 0n).toString(),
      poolsMigrated: (stats?.poolsMigrated ?? 0n).toString(),
      skinPurchases: stats?.skinPurchases ?? 0,
      skinPixels: (stats?.skinPixels ?? 0n).toString(),
    },
    blockNumber: stats?.blockNumber?.toString() ?? null,
    timestamp: stats?.timestamp?.toString() ?? null,
  });
});

// ──────────────────────────────────────────────
//  Rounds
// ──────────────────────────────────────────────

const ROUND_FILTERS = {
  all: undefined,
  upcoming: eq(schema.arenaRound.started, false),
  open: and(
    eq(schema.arenaRound.started, true),
    eq(schema.arenaRound.ended, false),
    eq(schema.arenaRound.cancelled, false),
  ),
  ended: eq(schema.arenaRound.ended, true),
  cancelled: eq(schema.arenaRound.cancelled, true),
} as const;

app.get("/arena/rounds", async (c) => {
  const { limit, offset } = parsePagination(c);
  const statusRaw = c.req.query("status") ?? "all";
  if (!ownKey(ROUND_FILTERS, statusRaw)) {
    return c.json({ error: `status must be one of ${Object.keys(ROUND_FILTERS).join(", ")}` }, 400);
  }
  const order = c.req.query("sort") === "asc" ? asc(schema.arenaRound.round) : desc(schema.arenaRound.round);
  const rows = await db
    .select()
    .from(schema.arenaRound)
    .where(ROUND_FILTERS[statusRaw])
    .orderBy(order)
    .limit(limit + 1)
    .offset(offset);
  return c.json({ rounds: rows.slice(0, limit).map(serializeRound), hasMore: rows.length > limit });
});

app.get("/arena/rounds/:round", async (c) => {
  const round = parseRound(c.req.param("round"));
  if (round === undefined) return c.json({ error: "Invalid round" }, 400);
  const row = await getRound(round);
  if (!row) return c.json({ error: "Round not found" }, 404);
  return c.json(serializeRound(row));
});

const PLAYER_LISTS = {
  // Every Normie that played, fixed when the round started.
  players: {
    where: (round: number) => and(eq(schema.arenaRoundPlayer.round, round), eq(schema.arenaRoundPlayer.played, true)),
    order: [asc(schema.arenaRoundPlayer.tokenId)],
  },
  // Normies credited a prize, in payout order.
  winners: {
    where: (round: number) =>
      and(eq(schema.arenaRoundPlayer.round, round), isNotNull(schema.arenaRoundPlayer.payoutOrder)),
    order: [asc(schema.arenaRoundPlayer.payoutOrder)],
  },
  // Normies credited the round's price back.
  refunds: {
    where: (round: number) => and(eq(schema.arenaRoundPlayer.round, round), isNotNull(schema.arenaRoundPlayer.refund)),
    order: [asc(schema.arenaRoundPlayer.tokenId)],
  },
} as const;

async function roundList(list: keyof typeof PLAYER_LISTS, round: number, limit: number, offset: number) {
  const { where, order } = PLAYER_LISTS[list];
  const rows = await db
    .select()
    .from(schema.arenaRoundPlayer)
    .where(where(round))
    .orderBy(...order)
    .limit(limit + 1)
    .offset(offset);
  const page = rows.slice(0, limit);
  const owners = await ownersOf(page.map((p) => p.tokenId));
  return {
    rows: page.map((p) => serializePlayer(p, owners.get(p.tokenId.toString()) ?? null)),
    hasMore: rows.length > limit,
  };
}

// Players by token id. A round can hold every registered Normie, so page through with offset.
app.get("/arena/rounds/:round/players", async (c) => {
  const round = parseRound(c.req.param("round"));
  if (round === undefined) return c.json({ error: "Invalid round" }, 400);
  const row = await getRound(round);
  if (!row) return c.json({ error: "Round not found" }, 404);
  const { limit, offset } = parsePagination(c, 500, 1000);
  const page = await roundList("players", round, limit, offset);
  return c.json({ round, status: roundStatus(row), total: row.players, players: page.rows, hasMore: page.hasMore });
});

// Prize credits in payout order. A round pays in calls of up to 300 entries; this lists them all.
app.get("/arena/rounds/:round/winners", async (c) => {
  const round = parseRound(c.req.param("round"));
  if (round === undefined) return c.json({ error: "Invalid round" }, 400);
  const row = await getRound(round);
  if (!row) return c.json({ error: "Round not found" }, 404);
  const { limit, offset } = parsePagination(c, 500, 1000);
  const page = await roundList("winners", round, limit, offset);
  return c.json({
    round,
    status: roundStatus(row),
    pool: (row.sponsorship + row.fees).toString(),
    prizes: row.prizes.toString(),
    total: row.winners,
    winners: page.rows,
    hasMore: page.hasMore,
  });
});

// Refunds of the round's price, by token id.
app.get("/arena/rounds/:round/refunds", async (c) => {
  const round = parseRound(c.req.param("round"));
  if (round === undefined) return c.json({ error: "Invalid round" }, 400);
  const row = await getRound(round);
  if (!row) return c.json({ error: "Round not found" }, 404);
  const { limit, offset } = parsePagination(c, 500, 1000);
  const page = await roundList("refunds", round, limit, offset);
  return c.json({
    round,
    status: roundStatus(row),
    price: row.price?.toString() ?? null,
    refunds: row.refunds.toString(),
    total: row.refundees,
    refundees: page.rows,
    hasMore: page.hasMore,
  });
});

// ──────────────────────────────────────────────
//  Registered Normies
// ──────────────────────────────────────────────

const REGISTERED_FILTERS = {
  all: inArray(schema.arenaNormie.state, [STATE_ACTIVE, STATE_SHORT]),
  active: eq(schema.arenaNormie.state, STATE_ACTIVE),
  short: eq(schema.arenaNormie.state, STATE_SHORT),
} as const;

/**
 * Registered Normies by token id. `active` ones play every round their balance covers; `short` ones sat out a
 * paid round they could not cover and play paid rounds again after a top-up or a credit. Both play free rounds.
 */
app.get("/arena/registered", async (c) => {
  const { limit, offset } = parsePagination(c, 100, 1000);
  const state = c.req.query("state") ?? "all";
  if (!ownKey(REGISTERED_FILTERS, state)) {
    return c.json({ error: `state must be one of ${Object.keys(REGISTERED_FILTERS).join(", ")}` }, 400);
  }
  const [rows, stats] = await Promise.all([
    db
      .select()
      .from(schema.arenaNormie)
      .where(REGISTERED_FILTERS[state])
      .orderBy(asc(schema.arenaNormie.tokenId))
      .limit(limit + 1)
      .offset(offset),
    getStats(),
  ]);
  const page = rows.slice(0, limit);
  const owners = await ownersOf(page.map((n) => n.tokenId));
  const active = stats?.activeCount ?? 0;
  const short = stats?.shortCount ?? 0;

  return c.json({
    state,
    total: state === "active" ? active : state === "short" ? short : active + short,
    normies: page.map((n) => {
      const owner = owners.get(n.tokenId.toString()) ?? null;
      return {
        tokenId: n.tokenId.toString(),
        state: stateName(n.state),
        balance: n.balance.toString(),
        agentId: n.agentId?.toString() ?? null,
        registeredRound: n.registeredRound,
        roundsPlayed: n.roundsPlayed,
        lastRound: n.lastRound,
        owner,
        burned: isBurnedOwner(owner),
      };
    }),
    hasMore: rows.length > limit,
  });
});

// ──────────────────────────────────────────────
//  Normies and holders
// ──────────────────────────────────────────────

app.get("/arena/normie/:id", async (c) => {
  const tokenId = parseTokenId(c.req.param("id"));
  if (tokenId === undefined) return c.json({ error: "Invalid token id" }, 400);

  const [[row], owners, stats] = await Promise.all([
    db.select().from(schema.arenaNormie).where(eq(schema.arenaNormie.tokenId, tokenId)).limit(1),
    ownersOf([tokenId]),
    getStats(),
  ]);
  const owner = owners.get(tokenId.toString()) ?? null;
  // Whether it plays (or played) the current round, as the storage's isPlayer answers.
  const currentRound = stats?.currentRound ?? 0;
  const [player] =
    row && currentRound > 0
      ? await db
          .select({ played: schema.arenaRoundPlayer.played })
          .from(schema.arenaRoundPlayer)
          .where(eq(schema.arenaRoundPlayer.id, `${currentRound}-${tokenId}`))
          .limit(1)
      : [];
  const inCurrentRound = player?.played ?? false;

  if (!row) {
    // Never touched the Arena: the same shape, all zero.
    return c.json({
      tokenId: tokenId.toString(),
      state: "unregistered",
      stateCode: 0,
      registered: false,
      level: "0",
      balance: "0",
      registeredRound: null,
      agentId: null,
      skins: 0,
      roundsPlayed: 0,
      lastRound: null,
      wins: 0,
      pixelsWon: "0",
      pixelsRefunded: "0",
      pixelsCharged: "0",
      deposited: "0",
      withdrawn: "0",
      migrated: "0",
      blockNumber: null,
      timestamp: null,
      owner,
      burned: isBurnedOwner(owner),
      inCurrentRound,
    });
  }
  return c.json({ ...serializeNormie(row, owner), inCurrentRound });
});

// The rounds a Normie played or was credited from, newest first.
app.get("/arena/normie/:id/rounds", async (c) => {
  const tokenId = parseTokenId(c.req.param("id"));
  if (tokenId === undefined) return c.json({ error: "Invalid token id" }, 400);
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select({ player: schema.arenaRoundPlayer, round: schema.arenaRound })
    .from(schema.arenaRoundPlayer)
    .innerJoin(schema.arenaRound, eq(schema.arenaRound.round, schema.arenaRoundPlayer.round))
    .where(eq(schema.arenaRoundPlayer.tokenId, tokenId))
    .orderBy(desc(schema.arenaRoundPlayer.round))
    .limit(limit + 1)
    .offset(offset);
  return c.json({
    tokenId: tokenId.toString(),
    rounds: rows.slice(0, limit).map(({ player, round }) => ({
      round: player.round,
      status: roundStatus(round),
      free: round.free,
      played: player.played,
      charged: player.charged.toString(),
      payoutOrder: player.payoutOrder,
      prize: player.prize?.toString() ?? null,
      refund: player.refund?.toString() ?? null,
      players: round.players,
      winners: round.winners,
      pool: (round.sponsorship + round.fees).toString(),
      timestamp: player.timestamp.toString(),
      txHash: player.txHash,
    })),
    hasMore: rows.length > limit,
  });
});

/** Every Normie a wallet holds that has Arena state, with the wallet's totals. Delegated Normies are not listed. */
app.get("/arena/holder/:address", async (c) => {
  const address = c.req.param("address").toLowerCase();
  if (!isAddress(address)) return c.json({ error: "Invalid Ethereum address" }, 400);

  const rows = await db
    .select({ normie: schema.arenaNormie })
    .from(schema.arenaNormie)
    .innerJoin(schema.normieOwner, eq(schema.normieOwner.tokenId, schema.arenaNormie.tokenId))
    .where(eq(schema.normieOwner.owner, address as `0x${string}`))
    .orderBy(asc(schema.arenaNormie.tokenId));

  let balance = 0n;
  let pixelsWon = 0n;
  let active = 0;
  let short = 0;
  for (const { normie } of rows) {
    balance += normie.balance;
    pixelsWon += normie.pixelsWon;
    if (normie.state === STATE_ACTIVE) active += 1;
    if (normie.state === STATE_SHORT) short += 1;
  }
  return c.json({
    address,
    balance: balance.toString(),
    pixelsWon: pixelsWon.toString(),
    registered: active + short,
    active,
    short,
    normies: rows.map(({ normie }) => serializeNormie(normie, address)),
  });
});

// ──────────────────────────────────────────────
//  Activity
// ──────────────────────────────────────────────

const EVENT_KINDS = [
  "deposit",
  "withdraw",
  "rescue",
  "prize",
  "refund",
  "sponsor",
  "sponsorship-moved",
  "sponsorship-released",
  "registered",
  "cleared",
  "agent-linked",
  "skin",
  "purchases-imported",
  "migrated",
  "round-started",
  "round-ended",
  "round-cancelled",
];
const SOURCES = ["v2", "v3"];

/** Arena events, newest first. Filters: `kind`, `source`, `round`, `tokenId`, `address`. */
app.get("/arena/activity", async (c) => {
  const { limit, offset } = parsePagination(c);
  const conditions = [];

  const kind = c.req.query("kind");
  if (kind !== undefined) {
    if (!EVENT_KINDS.includes(kind)) return c.json({ error: `kind must be one of ${EVENT_KINDS.join(", ")}` }, 400);
    conditions.push(eq(schema.arenaEvent.kind, kind));
  }
  const source = c.req.query("source");
  if (source !== undefined) {
    if (!SOURCES.includes(source)) return c.json({ error: `source must be one of ${SOURCES.join(", ")}` }, 400);
    conditions.push(eq(schema.arenaEvent.source, source));
  }
  const roundRaw = c.req.query("round");
  if (roundRaw !== undefined) {
    const round = parseRound(roundRaw);
    if (round === undefined) return c.json({ error: "Invalid round" }, 400);
    conditions.push(eq(schema.arenaEvent.round, round));
  }
  const tokenRaw = c.req.query("tokenId");
  if (tokenRaw !== undefined) {
    const tokenId = parseTokenId(tokenRaw);
    if (tokenId === undefined) return c.json({ error: "Invalid token id" }, 400);
    conditions.push(eq(schema.arenaEvent.tokenId, tokenId));
  }
  const address = c.req.query("address")?.toLowerCase();
  if (address !== undefined) {
    if (!isAddress(address)) return c.json({ error: "Invalid Ethereum address" }, 400);
    conditions.push(eq(schema.arenaEvent.account, address as `0x${string}`));
  }

  const rows = await db
    .select()
    .from(schema.arenaEvent)
    .where(conditions.length > 0 ? and(...conditions) : undefined)
    .orderBy(desc(schema.arenaEvent.blockNumber), desc(schema.arenaEvent.logIndex))
    .limit(limit + 1)
    .offset(offset);
  return c.json({ events: rows.slice(0, limit).map(serializeBigints), hasMore: rows.length > limit });
});

// ──────────────────────────────────────────────
//  Skins
// ──────────────────────────────────────────────

/**
 * Skin purchases, newest first, v2 history included. Filter by `buyer`. `total` is the storage's purchaseCount
 * (counts carried over from v2 plus v3 purchases). The skins themselves are made and served by the Arena app.
 */
app.get("/arena/skins", async (c) => {
  const { limit, offset } = parsePagination(c);
  const buyer = c.req.query("buyer")?.toLowerCase();
  if (buyer !== undefined && !isAddress(buyer)) return c.json({ error: "Invalid buyer" }, 400);

  const [rows, stats] = await Promise.all([
    db
      .select()
      .from(schema.arenaSkinPurchase)
      .where(buyer ? eq(schema.arenaSkinPurchase.buyer, buyer as `0x${string}`) : undefined)
      .orderBy(desc(schema.arenaSkinPurchase.blockNumber), desc(schema.arenaSkinPurchase.logIndex))
      .limit(limit + 1)
      .offset(offset),
    getStats(),
  ]);
  return c.json({
    total: stats?.skinPurchases ?? 0,
    pixels: (stats?.skinPixels ?? 0n).toString(),
    purchases: rows.slice(0, limit).map(serializeBigints),
    hasMore: rows.length > limit,
  });
});

/** A Normie's skin purchases. `count` is the storage's purchased(id), v2 purchases included. */
app.get("/arena/skins/normie/:id", async (c) => {
  const tokenId = parseTokenId(c.req.param("id"));
  if (tokenId === undefined) return c.json({ error: "Invalid token id" }, 400);
  const [rows, [normie]] = await Promise.all([
    db
      .select()
      .from(schema.arenaSkinPurchase)
      .where(eq(schema.arenaSkinPurchase.tokenId, tokenId))
      .orderBy(desc(schema.arenaSkinPurchase.blockNumber), desc(schema.arenaSkinPurchase.logIndex)),
    db
      .select({ skins: schema.arenaNormie.skins })
      .from(schema.arenaNormie)
      .where(eq(schema.arenaNormie.tokenId, tokenId))
      .limit(1),
  ]);
  return c.json({
    tokenId: tokenId.toString(),
    count: normie?.skins ?? 0,
    purchases: rows.map(serializeBigints),
  });
});

// ──────────────────────────────────────────────
//  Records
// ──────────────────────────────────────────────

const RECORD_SORTS = {
  pixels: [desc(schema.arenaNormie.pixelsWon), desc(schema.arenaNormie.wins), asc(schema.arenaNormie.tokenId)],
  wins: [desc(schema.arenaNormie.wins), desc(schema.arenaNormie.pixelsWon), asc(schema.arenaNormie.tokenId)],
  rounds: [desc(schema.arenaNormie.roundsPlayed), desc(schema.arenaNormie.wins), asc(schema.arenaNormie.tokenId)],
} as const;

/**
 * Normies by what the chain records of their rounds: `pixels` won (default), `wins` or `rounds` played.
 * Scores inside a round are kept by the Arena app, not on chain.
 */
app.get("/arena/records", async (c) => {
  const { limit, offset } = parsePagination(c);
  const sort = c.req.query("sort") ?? "pixels";
  if (!ownKey(RECORD_SORTS, sort)) {
    return c.json({ error: `sort must be one of ${Object.keys(RECORD_SORTS).join(", ")}` }, 400);
  }
  // `rounds` lists everyone who played; the other two only Normies that have won.
  const where = sort === "rounds" ? gt(schema.arenaNormie.roundsPlayed, 0) : gt(schema.arenaNormie.wins, 0);

  const rows = await db
    .select()
    .from(schema.arenaNormie)
    .where(where)
    .orderBy(...RECORD_SORTS[sort])
    .limit(limit + 1)
    .offset(offset);
  const page = rows.slice(0, limit);
  const owners = await ownersOf(page.map((n) => n.tokenId));
  return c.json({
    sort,
    normies: page.map((n) => ({
      tokenId: n.tokenId.toString(),
      pixelsWon: n.pixelsWon.toString(),
      wins: n.wins,
      roundsPlayed: n.roundsPlayed,
      lastRound: n.lastRound,
      agentId: n.agentId?.toString() ?? null,
      owner: owners.get(n.tokenId.toString()) ?? null,
    })),
    hasMore: rows.length > limit,
  });
});

export default app;

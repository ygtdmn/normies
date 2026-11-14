import { db } from "ponder:api";
import schema from "ponder:schema";
import { Hono } from "hono";
import { and, asc, count, desc, eq, gt, inArray, isNotNull, lt } from "ponder";
import { ownKey, queryInt } from "./query.js";

// ──────────────────────────────────────────────
//  Normies Arena read API: status, rounds, the line, Normie and holder state, skins, leaderboard.
//  Mounted at the root of the indexer API (see ./index.ts). Everything comes from NormiesArenaStorage events.
// ──────────────────────────────────────────────

const app = new Hono();
const GLOBAL_ID = "global";
const ZERO = "0x0000000000000000000000000000000000000000";
const DEAD = "0x000000000000000000000000000000000000dead";
const ID_BOUND = 10_000n;

type RoundRow = typeof schema.arenaRound.$inferSelect;
type NormieRow = typeof schema.arenaNormie.$inferSelect;
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

/** "upcoming" (sponsored, not started) | "open" | "finished" (waiting to be settled) | "settled" | "cancelled". */
function roundStatus(r: Pick<RoundRow, "started" | "finished" | "settled" | "cancelled">): string {
  if (r.cancelled) return "cancelled";
  if (r.settled) return "settled";
  if (r.finished) return "finished";
  return r.started ? "open" : "upcoming";
}

function serializeRound(r: RoundRow) {
  // How many winners the round pays: ceil(players * winnerBps / 10,000), as the contract counts them.
  const winnerCount = r.winnerBps === null ? null : Math.ceil((r.players * r.winnerBps) / 10_000);
  const { pendingCredits: _pending, ...row } = r;
  return {
    ...serializeBigints(row),
    status: roundStatus(r),
    admissionsOpen: r.started && !r.closed,
    pool: (r.sponsorship + r.fees).toString(),
    winnerCount,
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
    // The ticket only counts while the Normie is in the line.
    ticket: n.active ? n.ticket.toString() : null,
    inLine: n.active,
    owner,
    burned: isBurnedOwner(owner),
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

/** Place in the line, from 1: the Normies in the line holding an older ticket, plus one. */
async function linePosition(ticket: bigint): Promise<number> {
  const [row] = await db
    .select({ ahead: count() })
    .from(schema.arenaNormie)
    .where(and(eq(schema.arenaNormie.active, true), lt(schema.arenaNormie.ticket, ticket)));
  return (row?.ahead ?? 0) + 1;
}

// ──────────────────────────────────────────────
//  Status
// ──────────────────────────────────────────────

app.get("/arena/status", async (c) => {
  const stats = await getStats();
  const current = stats && stats.currentRound > 0 ? await getRound(stats.currentRound) : undefined;
  // Rounds sponsored ahead of time, and finished rounds that still wait for results or settlement.
  const [upcoming, unsettled] = await Promise.all([
    db.select().from(schema.arenaRound).where(eq(schema.arenaRound.started, false)).orderBy(asc(schema.arenaRound.round)),
    db
      .select({ round: schema.arenaRound.round })
      .from(schema.arenaRound)
      .where(
        and(
          eq(schema.arenaRound.finished, true),
          eq(schema.arenaRound.settled, false),
          eq(schema.arenaRound.cancelled, false),
        ),
      )
      .orderBy(asc(schema.arenaRound.round)),
  ]);

  return c.json({
    indexed: Boolean(process.env.PONDER_ARENA_STORAGE_ADDRESS),
    storage: process.env.PONDER_ARENA_STORAGE_ADDRESS?.toLowerCase() ?? null,
    currentRound: stats?.currentRound ?? 0,
    round: current ? serializeRound(current) : null,
    upcoming: upcoming.map(serializeRound),
    unsettledRounds: unsettled.map((r) => r.round),
    line: {
      waiting: stats?.inLine ?? 0,
      newestTicket: (stats?.newestTicket ?? 0n).toString(),
    },
    totals: {
      balances: (stats?.totalAllocated ?? 0n).toString(),
      pools: (stats?.totalPooled ?? 0n).toString(),
      roundsStarted: stats?.roundsStarted ?? 0,
      roundsSettled: stats?.roundsSettled ?? 0,
      roundsCancelled: stats?.roundsCancelled ?? 0,
      admissions: stats?.admissions ?? 0,
      pixelsPaid: (stats?.pixelsPaid ?? 0n).toString(),
      pixelsSponsored: (stats?.pixelsSponsored ?? 0n).toString(),
      pixelsDeposited: (stats?.pixelsDeposited ?? 0n).toString(),
      pixelsWithdrawn: (stats?.pixelsWithdrawn ?? 0n).toString(),
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
    eq(schema.arenaRound.finished, false),
    eq(schema.arenaRound.cancelled, false),
  ),
  finished: and(
    eq(schema.arenaRound.finished, true),
    eq(schema.arenaRound.settled, false),
    eq(schema.arenaRound.cancelled, false),
  ),
  settled: eq(schema.arenaRound.settled, true),
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

async function roundPlayers(round: number, winnersOnly: boolean, limit: number, offset: number) {
  const where = winnersOnly
    ? and(eq(schema.arenaRoundPlayer.round, round), isNotNull(schema.arenaRoundPlayer.rank))
    : and(eq(schema.arenaRoundPlayer.round, round), gt(schema.arenaRoundPlayer.seat, 0));
  const rows = await db
    .select()
    .from(schema.arenaRoundPlayer)
    .where(where)
    .orderBy(winnersOnly ? asc(schema.arenaRoundPlayer.rank) : asc(schema.arenaRoundPlayer.seat))
    .limit(limit + 1)
    .offset(offset);
  const page = rows.slice(0, limit);
  const owners = await ownersOf(page.map((p) => p.tokenId));
  return {
    players: page.map((p) => ({
      tokenId: p.tokenId.toString(),
      seat: p.seat,
      charged: p.charged.toString(),
      rank: p.rank,
      prize: p.prize?.toString() ?? null,
      refund: p.refund?.toString() ?? null,
      owner: owners.get(p.tokenId.toString()) ?? null,
      blockNumber: p.blockNumber.toString(),
      timestamp: p.timestamp.toString(),
      txHash: p.txHash,
    })),
    hasMore: rows.length > limit,
  };
}

// Players in admission order. A round holds at most 300, so one page can carry all of them.
app.get("/arena/rounds/:round/players", async (c) => {
  const round = parseRound(c.req.param("round"));
  if (round === undefined) return c.json({ error: "Invalid round" }, 400);
  const row = await getRound(round);
  if (!row) return c.json({ error: "Round not found" }, 404);
  const { limit, offset } = parsePagination(c, 300, 300);
  const page = await roundPlayers(round, false, limit, offset);
  return c.json({ round, status: roundStatus(row), total: row.players, ...page });
});

// Winners of a settled round, best first.
app.get("/arena/rounds/:round/winners", async (c) => {
  const round = parseRound(c.req.param("round"));
  if (round === undefined) return c.json({ error: "Invalid round" }, 400);
  const row = await getRound(round);
  if (!row) return c.json({ error: "Round not found" }, 404);
  const { limit, offset } = parsePagination(c, 300, 300);
  const page = await roundPlayers(round, true, limit, offset);
  return c.json({
    round,
    status: roundStatus(row),
    resultHash: row.resultHash,
    pool: (row.sponsorship + row.fees).toString(),
    total: row.winners,
    winners: page.players,
    hasMore: page.hasMore,
  });
});

// ──────────────────────────────────────────────
//  The line
// ──────────────────────────────────────────────

/**
 * Normies waiting in the line, oldest ticket first. `position` counts from 1. While a round takes admissions,
 * `eligible` tells whether the Normie's ticket is old enough for it (issued before the round started).
 */
app.get("/arena/queue", async (c) => {
  const { limit, offset } = parsePagination(c);
  const stats = await getStats();
  const current = stats && stats.currentRound > 0 ? await getRound(stats.currentRound) : undefined;
  const admitting = current && current.started && !current.closed ? current : undefined;

  const rows = await db
    .select()
    .from(schema.arenaNormie)
    .where(eq(schema.arenaNormie.active, true))
    .orderBy(asc(schema.arenaNormie.ticket))
    .limit(limit + 1)
    .offset(offset);
  const page = rows.slice(0, limit);
  const owners = await ownersOf(page.map((n) => n.tokenId));

  return c.json({
    total: stats?.inLine ?? 0,
    newestTicket: (stats?.newestTicket ?? 0n).toString(),
    admittingRound: admitting?.round ?? null,
    ticketCutoff: admitting?.ticketCutoff?.toString() ?? null,
    queue: page.map((n, i) => {
      const owner = owners.get(n.tokenId.toString()) ?? null;
      return {
        position: offset + i + 1,
        tokenId: n.tokenId.toString(),
        ticket: n.ticket.toString(),
        balance: n.balance.toString(),
        agentId: n.agentId?.toString() ?? null,
        owner,
        burned: isBurnedOwner(owner),
        eligible: admitting?.ticketCutoff != null ? n.ticket <= admitting.ticketCutoff : null,
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

  const [[row], owners] = await Promise.all([
    db.select().from(schema.arenaNormie).where(eq(schema.arenaNormie.tokenId, tokenId)).limit(1),
    ownersOf([tokenId]),
  ]);
  const owner = owners.get(tokenId.toString()) ?? null;
  if (!row) {
    // Never touched the Arena: the same shape, all zero.
    return c.json({
      tokenId: tokenId.toString(),
      balance: "0",
      ticket: null,
      active: false,
      inLine: false,
      needsFunds: false,
      agentId: null,
      skins: 0,
      roundsPlayed: 0,
      wins: 0,
      pixelsWon: "0",
      pixelsRefunded: "0",
      pixelsCharged: "0",
      deposited: "0",
      withdrawn: "0",
      lastRound: null,
      blockNumber: null,
      timestamp: null,
      owner,
      burned: isBurnedOwner(owner),
      position: null,
    });
  }
  return c.json({
    ...serializeNormie(row, owner),
    position: row.active ? await linePosition(row.ticket) : null,
  });
});

// The rounds a Normie played, newest first.
app.get("/arena/normie/:id/rounds", async (c) => {
  const tokenId = parseTokenId(c.req.param("id"));
  if (tokenId === undefined) return c.json({ error: "Invalid token id" }, 400);
  const { limit, offset } = parsePagination(c);

  const rows = await db
    .select({ player: schema.arenaRoundPlayer, round: schema.arenaRound })
    .from(schema.arenaRoundPlayer)
    .innerJoin(schema.arenaRound, eq(schema.arenaRound.round, schema.arenaRoundPlayer.round))
    .where(and(eq(schema.arenaRoundPlayer.tokenId, tokenId), gt(schema.arenaRoundPlayer.seat, 0)))
    .orderBy(desc(schema.arenaRoundPlayer.round))
    .limit(limit + 1)
    .offset(offset);
  return c.json({
    tokenId: tokenId.toString(),
    rounds: rows.slice(0, limit).map(({ player, round }) => ({
      round: player.round,
      status: roundStatus(round),
      seat: player.seat,
      charged: player.charged.toString(),
      rank: player.rank,
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
  let inLine = 0;
  let needsFunds = 0;
  for (const { normie } of rows) {
    balance += normie.balance;
    pixelsWon += normie.pixelsWon;
    if (normie.active) inLine += 1;
    if (normie.needsFunds) needsFunds += 1;
  }
  return c.json({
    address,
    balance: balance.toString(),
    pixelsWon: pixelsWon.toString(),
    inLine,
    needsFunds,
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
  "entry",
  "credit",
  "sponsor",
  "sponsorship-moved",
  "sponsorship-released",
  "enrolled",
  "left",
  "agent-linked",
  "skin",
];

/** Arena events, newest first. Filters: `kind`, `round`, `tokenId`, `address`. */
app.get("/arena/activity", async (c) => {
  const { limit, offset } = parsePagination(c);
  const conditions = [];

  const kind = c.req.query("kind");
  if (kind !== undefined) {
    if (!EVENT_KINDS.includes(kind)) return c.json({ error: `kind must be one of ${EVENT_KINDS.join(", ")}` }, 400);
    conditions.push(eq(schema.arenaEvent.kind, kind));
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

/** Skin purchases, newest first. Filter by `buyer`. The skins themselves are made and served by the Arena app. */
app.get("/arena/skins", async (c) => {
  const { limit, offset } = parsePagination(c);
  const buyer = c.req.query("buyer")?.toLowerCase();
  if (buyer !== undefined && !isAddress(buyer)) return c.json({ error: "Invalid buyer" }, 400);

  const [rows, stats] = await Promise.all([
    db
      .select()
      .from(schema.arenaSkinPurchase)
      .where(buyer ? eq(schema.arenaSkinPurchase.buyer, buyer as `0x${string}`) : undefined)
      .orderBy(desc(schema.arenaSkinPurchase.purchaseId))
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

app.get("/arena/skins/normie/:id", async (c) => {
  const tokenId = parseTokenId(c.req.param("id"));
  if (tokenId === undefined) return c.json({ error: "Invalid token id" }, 400);
  const rows = await db
    .select()
    .from(schema.arenaSkinPurchase)
    .where(eq(schema.arenaSkinPurchase.tokenId, tokenId))
    .orderBy(desc(schema.arenaSkinPurchase.purchaseId));
  return c.json({ tokenId: tokenId.toString(), count: rows.length, purchases: rows.map(serializeBigints) });
});

// ──────────────────────────────────────────────
//  Leaderboard
// ──────────────────────────────────────────────

const LEADERBOARD_SORTS = {
  pixels: [desc(schema.arenaNormie.pixelsWon), desc(schema.arenaNormie.wins), asc(schema.arenaNormie.tokenId)],
  wins: [desc(schema.arenaNormie.wins), desc(schema.arenaNormie.pixelsWon), asc(schema.arenaNormie.tokenId)],
  rounds: [desc(schema.arenaNormie.roundsPlayed), desc(schema.arenaNormie.wins), asc(schema.arenaNormie.tokenId)],
} as const;

/**
 * Normies by what the chain records of their rounds: `pixels` won (default), `wins` or `rounds` played.
 * Scores inside a round are kept by the Arena app, not on chain.
 */
app.get("/arena/leaderboard", async (c) => {
  const { limit, offset } = parsePagination(c);
  const sort = c.req.query("sort") ?? "pixels";
  if (!ownKey(LEADERBOARD_SORTS, sort)) {
    return c.json({ error: `sort must be one of ${Object.keys(LEADERBOARD_SORTS).join(", ")}` }, 400);
  }
  // `rounds` lists everyone who played; the other two only Normies that have won.
  const where = sort === "rounds" ? gt(schema.arenaNormie.roundsPlayed, 0) : gt(schema.arenaNormie.wins, 0);

  const rows = await db
    .select()
    .from(schema.arenaNormie)
    .where(where)
    .orderBy(...LEADERBOARD_SORTS[sort])
    .limit(limit + 1)
    .offset(offset);
  const page = rows.slice(0, limit);
  const owners = await ownersOf(page.map((n) => n.tokenId));
  return c.json({
    sort,
    leaderboard: page.map((n, i) => ({
      position: offset + i + 1,
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

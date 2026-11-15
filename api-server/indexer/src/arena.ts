import { ponder } from "ponder:registry";
import {
  arenaEvent,
  arenaNormie,
  arenaRound,
  arenaRoundPlayer,
  arenaSkinPurchase,
  arenaStats,
} from "ponder:schema";
import { and, count, eq, inArray, sql } from "ponder";
import { eventMeta, type EventMeta, type IndexingContext } from "./lib/canvas-state.js";

// ──────────────────────────────────────────────
//  Normies Arena handlers (v3). Every event comes from NormiesArenaStorage; each handler mirrors the one state
//  change its setter makes, so the tables track the contract field by field.
//
//  Balances, levels and states come only from Leveled, which the storage emits after every per-Normie write, and
//  from the bulk update at a paid RoundStarted (the one change without a per-Normie event). Deposited, Withdrawn,
//  Credited, Cleared and Rescued only add lifetime totals and activity, so nothing is counted twice.
//
//  Registered only when PONDER_ARENA_V3_STORAGE_ADDRESS is set (see ponder.config.ts): Ponder refuses handlers for
//  a contract that is not in the config. The retired v2 storage gets history-only handlers at the bottom.
// ──────────────────────────────────────────────

const GLOBAL_ID = "global";

const STATE_UNREGISTERED = 0;
const STATE_ACTIVE = 1;
const STATE_SHORT = 2;
const STATE_CLEARED = 3;

/** Player rows written per insert at a round start: a round can hold every registered Normie (up to 10,000). */
const PLAYER_INSERT_CHUNK = 1_000;

type RoundRow = typeof arenaRound.$inferSelect;
type NormieRow = typeof arenaNormie.$inferSelect;
type PlayerRow = typeof arenaRoundPlayer.$inferSelect;
type StatsRow = typeof arenaStats.$inferSelect;
type Meta = EventMeta & { logIndex: number };
type Source = "v2" | "v3";

/** The v2 storage: v3 Deposited and Sponsored events from it are the cutover moving v2 balances and pools. */
const LEGACY = process.env.PONDER_ARENA_V2_STORAGE_ADDRESS?.toLowerCase();

function isLegacy(account: string): boolean {
  return LEGACY !== undefined && account.toLowerCase() === LEGACY;
}

function metaOf(event: Parameters<typeof eventMeta>[0] & { log: { logIndex: number } }): Meta {
  return { ...eventMeta(event), logIndex: Number(event.log.logIndex) };
}

function blankRound(round: number, meta: Meta): RoundRow {
  return {
    round,
    sponsorship: 0n,
    fees: 0n,
    unpaid: 0n,
    paid: 0n,
    prizes: 0n,
    refunds: 0n,
    winners: 0,
    refundees: 0,
    rolled: 0n,
    rolledIn: 0n,
    migrated: 0n,
    started: false,
    ended: false,
    cancelled: false,
    price: null,
    free: null,
    cumulative: null,
    players: 0,
    startedAt: null,
    startedBlock: null,
    startedTxHash: null,
    endedAt: null,
    endedTxHash: null,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
  };
}

function blankNormie(tokenId: bigint, meta: Meta): NormieRow {
  return {
    tokenId,
    state: STATE_UNREGISTERED,
    level: 0n,
    balance: 0n,
    registeredRound: null,
    agentId: null,
    skins: 0,
    roundsPlayed: 0,
    lastRound: null,
    wins: 0,
    pixelsWon: 0n,
    pixelsRefunded: 0n,
    pixelsCharged: 0n,
    deposited: 0n,
    withdrawn: 0n,
    migrated: 0n,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
  };
}

function blankStats(meta: Meta): StatsRow {
  return {
    id: GLOBAL_ID,
    currentRound: 0,
    currentFree: false,
    cumulative: 0n,
    activeCount: 0,
    shortCount: 0,
    clearedCount: 0,
    totalAllocated: 0n,
    totalPooled: 0n,
    roundsStarted: 0,
    roundsEnded: 0,
    roundsCancelled: 0,
    playerEntries: 0,
    pixelsCharged: 0n,
    prizes: 0n,
    refunds: 0n,
    pixelsSponsored: 0n,
    pixelsDeposited: 0n,
    pixelsWithdrawn: 0n,
    pixelsRescued: 0n,
    balancesMigrated: 0n,
    poolsMigrated: 0n,
    skinPurchases: 0,
    skinPixels: 0n,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
  };
}

/** Read a round (or a blank one), apply `patch`, write it back. Returns the row as written. */
async function patchRound(
  context: IndexingContext,
  round: number,
  patch: (current: RoundRow) => Partial<RoundRow>,
  meta: Meta,
): Promise<RoundRow> {
  const current = (await context.db.find(arenaRound, { round })) ?? blankRound(round, meta);
  const next = { ...current, ...patch(current), blockNumber: meta.blockNumber, timestamp: meta.timestamp };
  const { round: _key, ...values } = next;
  await context.db.insert(arenaRound).values(next).onConflictDoUpdate(values);
  return next;
}

async function patchNormie(
  context: IndexingContext,
  tokenId: bigint,
  patch: (current: NormieRow) => Partial<NormieRow>,
  meta: Meta,
): Promise<{ before: NormieRow; after: NormieRow }> {
  const before = (await context.db.find(arenaNormie, { tokenId })) ?? blankNormie(tokenId, meta);
  const after = { ...before, ...patch(before), blockNumber: meta.blockNumber, timestamp: meta.timestamp };
  const { tokenId: _key, ...values } = after;
  await context.db.insert(arenaNormie).values(after).onConflictDoUpdate(values);
  return { before, after };
}

async function patchStats(
  context: IndexingContext,
  patch: (current: StatsRow) => Partial<StatsRow>,
  meta: Meta,
): Promise<void> {
  const current = (await context.db.find(arenaStats, { id: GLOBAL_ID })) ?? blankStats(meta);
  const next = { ...current, ...patch(current), blockNumber: meta.blockNumber, timestamp: meta.timestamp };
  const { id: _key, ...values } = next;
  await context.db.insert(arenaStats).values(next).onConflictDoUpdate(values);
}

/** Read a round's row for a Normie (or a blank one that did not play), apply `patch`, write it back. */
async function patchPlayer(
  context: IndexingContext,
  round: number,
  tokenId: bigint,
  patch: (current: PlayerRow) => Partial<PlayerRow>,
  meta: Meta,
): Promise<void> {
  const id = `${round}-${tokenId}`;
  const current = (await context.db.find(arenaRoundPlayer, { id })) ?? {
    id,
    round,
    tokenId,
    played: false,
    charged: 0n,
    payoutOrder: null,
    prize: null,
    refund: null,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
  };
  const next = { ...current, ...patch(current) };
  const { id: _key, ...values } = next;
  await context.db.insert(arenaRoundPlayer).values(next).onConflictDoUpdate(values);
}

async function logEvent(
  context: IndexingContext,
  meta: Meta,
  row: {
    kind: string;
    source?: Source;
    round?: number;
    tokenId?: bigint;
    account?: `0x${string}`;
    amount?: bigint;
    ref?: bigint;
  },
): Promise<void> {
  await context.db.insert(arenaEvent).values({
    // Log indexes are unique per block across contracts, so v2 and v3 rows never collide.
    id: `${meta.blockNumber}-${meta.logIndex}`,
    kind: row.kind,
    source: row.source ?? "v3",
    round: row.round ?? null,
    tokenId: row.tokenId ?? null,
    account: row.account ?? null,
    amount: row.amount ?? null,
    ref: row.ref ?? null,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
    logIndex: meta.logIndex,
  });
}

const STATE_COUNTERS = {
  [STATE_ACTIVE]: "activeCount",
  [STATE_SHORT]: "shortCount",
  [STATE_CLEARED]: "clearedCount",
} as const satisfies Record<number, keyof StatsRow>;

function counterOf(state: number): (typeof STATE_COUNTERS)[keyof typeof STATE_COUNTERS] | undefined {
  return STATE_COUNTERS[state as keyof typeof STATE_COUNTERS];
}

/** The state counters after one Normie moved from state `from` to state `to`. */
function shiftState(s: StatsRow, from: number, to: number): Partial<StatsRow> {
  const patch: Partial<StatsRow> = {};
  const out = counterOf(from);
  const into = counterOf(to);
  if (out) patch[out] = s[out] - 1;
  if (into) patch[into] = (patch[into] ?? s[into]) + 1;
  return patch;
}

/**
 * Applies a RoundStarted to every Normie with raw SQL and writes the round's players. Mirrors
 * test/arena/NormiesArenaEvents.t.sol, which proves the rule against the contract:
 *   paid, new C and Cprev = C - price: every active Normie with level < C turns short with balance = level - Cprev
 *   (its level becomes that balance, as the contract stores it on its next write); every other active Normie is
 *   charged and its balance becomes level - C. The players are the active Normies after that.
 *   free: nothing is charged; the players are every registered Normie (active or short).
 * Raw SQL flushes Ponder's cache first, so it runs before any other write of this handler and sees every earlier
 * event, this block's included. Returns how many players it found.
 */
async function applyRoundStart(
  context: IndexingContext,
  round: number,
  price: bigint,
  free: boolean,
  cumulative: bigint,
  meta: Meta,
): Promise<number> {
  const db = context.db.sql;
  const level = arenaNormie.level;
  const players = free
    ? inArray(arenaNormie.state, [STATE_ACTIVE, STATE_SHORT])
    : eq(arenaNormie.state, STATE_ACTIVE);

  if (!free) {
    const previous = (cumulative - price).toString();
    const now = cumulative.toString();
    // Drop-outs first, so the charge below only reaches Normies that covered the price.
    await db
      .update(arenaNormie)
      .set({
        state: STATE_SHORT,
        level: sql`${level} - ${previous}::numeric`,
        balance: sql`${level} - ${previous}::numeric`,
      })
      .where(and(eq(arenaNormie.state, STATE_ACTIVE), sql`${level} < ${now}::numeric`));
    await db
      .update(arenaNormie)
      .set({
        balance: sql`${level} - ${now}::numeric`,
        pixelsCharged: sql`${arenaNormie.pixelsCharged} + ${price.toString()}::numeric`,
        roundsPlayed: sql`${arenaNormie.roundsPlayed} + 1`,
        lastRound: round,
      })
      .where(eq(arenaNormie.state, STATE_ACTIVE));
  } else {
    await db
      .update(arenaNormie)
      .set({ roundsPlayed: sql`${arenaNormie.roundsPlayed} + 1`, lastRound: round })
      .where(players);
  }

  const ids = await db
    .select({ tokenId: arenaNormie.tokenId })
    .from(arenaNormie)
    .where(players)
    .orderBy(arenaNormie.tokenId);
  const charged = free ? 0n : price;
  for (let i = 0; i < ids.length; i += PLAYER_INSERT_CHUNK) {
    await context.db.insert(arenaRoundPlayer).values(
      ids.slice(i, i + PLAYER_INSERT_CHUNK).map(({ tokenId }) => ({
        id: `${round}-${tokenId}`,
        round,
        tokenId,
        played: true,
        charged,
        payoutOrder: null,
        prize: null,
        refund: null,
        blockNumber: meta.blockNumber,
        timestamp: meta.timestamp,
        txHash: meta.txHash,
      })),
    );
  }

  // Recount the states from the table, so the counters always match the rows.
  const counts = await db
    .select({ state: arenaNormie.state, n: count() })
    .from(arenaNormie)
    .groupBy(arenaNormie.state);
  const byState = new Map(counts.map((c) => [c.state, Number(c.n)]));
  await patchStats(
    context,
    () => ({
      activeCount: byState.get(STATE_ACTIVE) ?? 0,
      shortCount: byState.get(STATE_SHORT) ?? 0,
      clearedCount: byState.get(STATE_CLEARED) ?? 0,
    }),
    meta,
  );
  return ids.length;
}

/** RoundEnded / RoundCancelled: the storage's paid total is authoritative; the credits should add up to it. */
async function closeRound(
  context: IndexingContext,
  round: number,
  paid: bigint,
  rolled: bigint,
  at: bigint,
  cancelled: boolean,
  meta: Meta,
): Promise<void> {
  const row = await patchRound(
    context,
    round,
    () => ({
      ...(cancelled ? { cancelled: true } : { ended: true }),
      paid,
      rolled,
      endedAt: at,
      endedTxHash: meta.txHash,
    }),
    meta,
  );
  if (row.prizes + row.refunds !== paid) {
    console.warn(`Arena round ${round}: the storage paid ${paid}, the credits add up to ${row.prizes + row.refunds}`);
  }
  await patchStats(
    context,
    (s) => (cancelled ? { roundsCancelled: s.roundsCancelled + 1 } : { roundsEnded: s.roundsEnded + 1 }),
    meta,
  );
  await logEvent(context, meta, {
    kind: cancelled ? "round-cancelled" : "round-ended",
    round,
    amount: paid,
    ref: rolled,
  });
}

if (process.env.PONDER_ARENA_V3_STORAGE_ADDRESS) {
  // ── Normies ──

  // _save: the record as written. The only per-Normie source of balance, level and state.
  ponder.on("NormiesArenaStorage:Leveled", async ({ event, context }) => {
    const { id, balance, level } = event.args;
    const state = Number(event.args.state);
    const meta = metaOf(event);
    const { before } = await patchNormie(context, id, () => ({ state, level, balance }), meta);
    if (before.state !== state) await patchStats(context, (s) => shiftState(s, before.state, state), meta);
  });

  // _register: registered while `round` was open; it plays from the next round. Leveled follows.
  ponder.on("NormiesArenaStorage:Registered", async ({ event, context }) => {
    const { id } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    await patchNormie(context, id, () => ({ registeredRound: round }), meta);
    await logEvent(context, meta, { kind: "registered", round, tokenId: id });
  });

  // _clear: a burned Normie out of the game, its balance frozen for rescue. Leveled (state 3) follows.
  ponder.on("NormiesArenaStorage:Cleared", async ({ event, context }) => {
    const { id, balance } = event.args;
    await logEvent(context, metaOf(event), { kind: "cleared", tokenId: id, amount: balance });
  });

  ponder.on("NormiesArenaStorage:AgentLinked", async ({ event, context }) => {
    const { id, agentId } = event.args;
    const meta = metaOf(event);
    await patchNormie(context, id, () => ({ agentId }), meta);
    await logEvent(context, meta, { kind: "agent-linked", tokenId: id, ref: agentId });
  });

  // ── Balances ──

  // deposit: a top-up from a wallet, or (from the v2 storage) a v2 balance moved at the cutover. Leveled follows.
  ponder.on("NormiesArenaStorage:Deposited", async ({ event, context }) => {
    const { id, from, amount } = event.args;
    const meta = metaOf(event);
    const migrated = isLegacy(from);
    await patchNormie(
      context,
      id,
      (n) => (migrated ? { migrated: n.migrated + amount } : { deposited: n.deposited + amount }),
      meta,
    );
    await patchStats(
      context,
      (s) => ({
        totalAllocated: s.totalAllocated + amount,
        ...(migrated
          ? { balancesMigrated: s.balancesMigrated + amount }
          : { pixelsDeposited: s.pixelsDeposited + amount }),
      }),
      meta,
    );
    await logEvent(context, meta, { kind: migrated ? "migrated" : "deposit", tokenId: id, account: from, amount });
  });

  // _withdraw: paid to the Normie's holder. Its Leveled came just before.
  ponder.on("NormiesArenaStorage:Withdrawn", async ({ event, context }) => {
    const { id, to, amount } = event.args;
    const meta = metaOf(event);
    await patchNormie(context, id, (n) => ({ withdrawn: n.withdrawn + amount }), meta);
    await patchStats(
      context,
      (s) => ({ totalAllocated: s.totalAllocated - amount, pixelsWithdrawn: s.pixelsWithdrawn + amount }),
      meta,
    );
    await logEvent(context, meta, { kind: "withdraw", tokenId: id, account: to, amount });
  });

  // rescue: a burned Normie's whole balance leaves. Its Leveled (balance 0, state 3) came just before.
  ponder.on("NormiesArenaStorage:Rescued", async ({ event, context }) => {
    const { id, to, amount } = event.args;
    const meta = metaOf(event);
    await patchStats(
      context,
      (s) => ({ totalAllocated: s.totalAllocated - amount, pixelsRescued: s.pixelsRescued + amount }),
      meta,
    );
    await logEvent(context, meta, { kind: "rescue", tokenId: id, account: to, amount });
  });

  // _credit: the open round's pool -> balance, as a refund (the round's price) or a prize. Refunds come first in
  // each payout call; a prize's order is its place among the round's prize credits. Leveled follows.
  ponder.on("NormiesArenaStorage:Credited", async ({ event, context }) => {
    const { id, amount, refund } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    const existing = await context.db.find(arenaRoundPlayer, { id: `${round}-${id}` });
    const first = refund ? existing?.refund == null : existing?.prize == null;
    const row = await patchRound(
      context,
      round,
      (r) => ({
        unpaid: r.unpaid - amount,
        paid: r.paid + amount,
        ...(refund
          ? { refunds: r.refunds + amount, refundees: r.refundees + (first ? 1 : 0) }
          : { prizes: r.prizes + amount, winners: r.winners + (first ? 1 : 0) }),
      }),
      meta,
    );
    await patchPlayer(
      context,
      round,
      id,
      (p) =>
        refund
          ? { refund: (p.refund ?? 0n) + amount }
          : { prize: (p.prize ?? 0n) + amount, payoutOrder: p.payoutOrder ?? row.winners },
      meta,
    );
    await patchNormie(
      context,
      id,
      (n) =>
        refund
          ? { pixelsRefunded: n.pixelsRefunded + amount }
          : { pixelsWon: n.pixelsWon + amount, wins: n.wins + (first ? 1 : 0) },
      meta,
    );
    await patchStats(
      context,
      (s) => ({
        totalAllocated: s.totalAllocated + amount,
        totalPooled: s.totalPooled - amount,
        ...(refund ? { refunds: s.refunds + amount } : { prizes: s.prizes + amount }),
      }),
      meta,
    );
    await logEvent(context, meta, { kind: refund ? "refund" : "prize", round, tokenId: id, amount });
  });

  // ── Pools ──

  // addSponsorship: from a sponsor, or (from the v2 storage) a v2 pool moved at the cutover.
  ponder.on("NormiesArenaStorage:Sponsored", async ({ event, context }) => {
    const { from, amount } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    const migrated = isLegacy(from);
    await patchRound(
      context,
      round,
      (r) => ({
        sponsorship: r.sponsorship + amount,
        unpaid: r.unpaid + amount,
        ...(migrated ? { migrated: r.migrated + amount } : {}),
      }),
      meta,
    );
    await patchStats(
      context,
      (s) => ({
        totalPooled: s.totalPooled + amount,
        ...(migrated ? { poolsMigrated: s.poolsMigrated + amount } : { pixelsSponsored: s.pixelsSponsored + amount }),
      }),
      meta,
    );
    await logEvent(context, meta, { kind: migrated ? "migrated" : "sponsor", round, account: from, amount });
  });

  // _roll: an ended or cancelled round's unpaid pool becomes the next round's sponsorship. RoundEnded or
  // RoundCancelled follows.
  ponder.on("NormiesArenaStorage:SponsorshipMoved", async ({ event, context }) => {
    const { amount } = event.args;
    const from = Number(event.args.from);
    const to = Number(event.args.to);
    const meta = metaOf(event);
    await patchRound(context, from, (r) => ({ unpaid: r.unpaid - amount, rolled: r.rolled + amount }), meta);
    await patchRound(
      context,
      to,
      (r) => ({ sponsorship: r.sponsorship + amount, unpaid: r.unpaid + amount, rolledIn: r.rolledIn + amount }),
      meta,
    );
    await logEvent(context, meta, { kind: "sponsorship-moved", round: from, amount, ref: BigInt(to) });
  });

  ponder.on("NormiesArenaStorage:SponsorshipReleased", async ({ event, context }) => {
    const { to, amount } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    await patchRound(
      context,
      round,
      (r) => ({ sponsorship: r.sponsorship - amount, unpaid: r.unpaid - amount }),
      meta,
    );
    await patchStats(context, (s) => ({ totalPooled: s.totalPooled - amount }), meta);
    await logEvent(context, meta, { kind: "sponsorship-released", round, account: to, amount });
  });

  // ── Rounds ──

  ponder.on("NormiesArenaStorage:RoundStarted", async ({ event, context }) => {
    const { price, free, players, fees, cumulative, at } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    const counted = await applyRoundStart(context, round, price, free, cumulative, meta);
    if (BigInt(counted) !== players) {
      console.warn(`Arena round ${round}: RoundStarted reports ${players} players, the replay found ${counted}`);
    }
    await patchRound(
      context,
      round,
      (r) => ({
        started: true,
        price,
        free,
        cumulative,
        players: Number(players),
        fees,
        unpaid: r.unpaid + fees,
        startedAt: at,
        startedBlock: meta.blockNumber,
        startedTxHash: meta.txHash,
      }),
      meta,
    );
    await patchStats(
      context,
      (s) => ({
        currentRound: round,
        currentFree: free,
        cumulative,
        roundsStarted: s.roundsStarted + 1,
        playerEntries: s.playerEntries + Number(players),
        pixelsCharged: s.pixelsCharged + fees,
        totalAllocated: s.totalAllocated - fees,
        totalPooled: s.totalPooled + fees,
      }),
      meta,
    );
    await logEvent(context, meta, { kind: "round-started", round, amount: fees, ref: players });
  });

  // endRound: every payout call came before. The unpaid pool rolled to the next round (SponsorshipMoved).
  ponder.on("NormiesArenaStorage:RoundEnded", async ({ event, context }) => {
    const { paid, rolled, at } = event.args;
    await closeRound(context, Number(event.args.round), paid, rolled, at, false, metaOf(event));
  });

  // cancelRound: credits already made stay, nothing is refunded and C stays as it is.
  ponder.on("NormiesArenaStorage:RoundCancelled", async ({ event, context }) => {
    const { paid, rolled, at } = event.args;
    await closeRound(context, Number(event.args.round), paid, rolled, at, true, metaOf(event));
  });

  // ── Skins ──

  ponder.on("NormiesArenaStorage:SkinPurchased", async ({ event, context }) => {
    const { purchaseId, id, buyer, price } = event.args;
    const meta = metaOf(event);
    await context.db.insert(arenaSkinPurchase).values({
      id: `v3-${purchaseId}`,
      source: "v3",
      purchaseId,
      tokenId: id,
      buyer,
      price,
      blockNumber: meta.blockNumber,
      timestamp: meta.timestamp,
      txHash: meta.txHash,
      logIndex: meta.logIndex,
    });
    await patchNormie(context, id, (n) => ({ skins: n.skins + 1 }), meta);
    await patchStats(
      context,
      (s) => ({ skinPurchases: s.skinPurchases + 1, skinPixels: s.skinPixels + price }),
      meta,
    );
    await logEvent(context, meta, { kind: "skin", tokenId: id, account: buyer, amount: price, ref: purchaseId });
  });

  // importPurchases: the cutover sets a Normie's count to its v2 count (overwrite, like the storage).
  ponder.on("NormiesArenaStorage:PurchasesImported", async ({ event, context }) => {
    const { id } = event.args;
    const imported = Number(event.args.count);
    const meta = metaOf(event);
    const { before } = await patchNormie(context, id, () => ({ skins: imported }), meta);
    await patchStats(context, (s) => ({ skinPurchases: s.skinPurchases - before.skins + imported }), meta);
    await logEvent(context, meta, { kind: "purchases-imported", tokenId: id, ref: event.args.count });
  });
}

// ──────────────────────────────────────────────
//  Arena v2 history. The retired storage's money moves and skin purchases become activity rows (source "v2")
//  and purchase rows; they never touch Normies, balances, rounds or counters, since the cutover brought every
//  v2 balance, pool and purchase count into v3 through v3 events. Its line, rounds and charges are not indexed.
// ──────────────────────────────────────────────

if (process.env.PONDER_ARENA_V2_STORAGE_ADDRESS) {
  ponder.on("NormiesArenaStorageV2:Deposited", async ({ event, context }) => {
    const { id, from, amount } = event.args;
    await logEvent(context, metaOf(event), { kind: "deposit", source: "v2", tokenId: id, account: from, amount });
  });

  ponder.on("NormiesArenaStorageV2:Withdrawn", async ({ event, context }) => {
    const { id, to, amount } = event.args;
    await logEvent(context, metaOf(event), { kind: "withdraw", source: "v2", tokenId: id, account: to, amount });
  });

  ponder.on("NormiesArenaStorageV2:Rescued", async ({ event, context }) => {
    const { id, to, amount } = event.args;
    await logEvent(context, metaOf(event), { kind: "rescue", source: "v2", tokenId: id, account: to, amount });
  });

  ponder.on("NormiesArenaStorageV2:Sponsored", async ({ event, context }) => {
    const { from, amount } = event.args;
    await logEvent(context, metaOf(event), {
      kind: "sponsor",
      source: "v2",
      round: Number(event.args.round),
      account: from,
      amount,
    });
  });

  // v2 purchase ids run 1..N; v3 continues at N + 1. The Normie's count arrives with v3 PurchasesImported.
  ponder.on("NormiesArenaStorageV2:SkinPurchased", async ({ event, context }) => {
    const { purchaseId, id, buyer, price } = event.args;
    const meta = metaOf(event);
    await context.db.insert(arenaSkinPurchase).values({
      id: `v2-${purchaseId}`,
      source: "v2",
      purchaseId,
      tokenId: id,
      buyer,
      price,
      blockNumber: meta.blockNumber,
      timestamp: meta.timestamp,
      txHash: meta.txHash,
      logIndex: meta.logIndex,
    });
    await patchStats(context, (s) => ({ skinPixels: s.skinPixels + price }), meta);
    await logEvent(context, meta, {
      kind: "skin",
      source: "v2",
      tokenId: id,
      account: buyer,
      amount: price,
      ref: purchaseId,
    });
  });
}

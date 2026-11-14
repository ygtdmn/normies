import { ponder } from "ponder:registry";
import {
  arenaEvent,
  arenaNormie,
  arenaRound,
  arenaRoundPlayer,
  arenaSkinPurchase,
  arenaStats,
} from "ponder:schema";
import { eventMeta, type EventMeta, type IndexingContext } from "./lib/canvas-state.js";

// ──────────────────────────────────────────────
//  Normies Arena handlers. Every event comes from NormiesArenaStorage; each handler mirrors the one state
//  change its setter makes, so the tables track the contract field by field.
//
//  Registered only when PONDER_ARENA_STORAGE_ADDRESS is set (see ponder.config.ts): Ponder refuses handlers for
//  a contract that is not in the config.
// ──────────────────────────────────────────────

const GLOBAL_ID = "global";

type RoundRow = typeof arenaRound.$inferSelect;
type NormieRow = typeof arenaNormie.$inferSelect;
type StatsRow = typeof arenaStats.$inferSelect;
type Meta = EventMeta & { logIndex: number };

function metaOf(event: Parameters<typeof eventMeta>[0] & { log: { logIndex: number } }): Meta {
  return { ...eventMeta(event), logIndex: Number(event.log.logIndex) };
}

function blankRound(round: number, meta: Meta): RoundRow {
  return {
    round,
    sponsorship: 0n,
    fees: 0n,
    unpaid: 0n,
    resultHash: null,
    started: false,
    closed: false,
    finished: false,
    settled: false,
    cancelled: false,
    ticketCutoff: null,
    capacity: null,
    price: null,
    winnerBps: null,
    free: null,
    players: 0,
    winners: 0,
    paid: 0n,
    refunded: 0n,
    movedOut: 0n,
    carriedTo: null,
    pendingCredits: null,
    startedAt: null,
    startedBlock: null,
    startedTxHash: null,
    finishedAt: null,
    finishedTxHash: null,
    endedAt: null,
    endedTxHash: null,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
  };
}

function blankNormie(tokenId: bigint, meta: Meta): NormieRow {
  return {
    tokenId,
    balance: 0n,
    ticket: 0n,
    active: false,
    needsFunds: false,
    agentId: null,
    skins: 0,
    roundsPlayed: 0,
    wins: 0,
    pixelsWon: 0n,
    pixelsRefunded: 0n,
    pixelsCharged: 0n,
    deposited: 0n,
    withdrawn: 0n,
    lastRound: null,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
  };
}

function blankStats(meta: Meta): StatsRow {
  return {
    id: GLOBAL_ID,
    currentRound: 0,
    newestTicket: 0n,
    inLine: 0,
    totalAllocated: 0n,
    totalPooled: 0n,
    roundsStarted: 0,
    roundsSettled: 0,
    roundsCancelled: 0,
    admissions: 0,
    pixelsPaid: 0n,
    pixelsSponsored: 0n,
    pixelsDeposited: 0n,
    pixelsWithdrawn: 0n,
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

async function patchPlayer(
  context: IndexingContext,
  round: number,
  tokenId: bigint,
  patch: (current: typeof arenaRoundPlayer.$inferSelect) => Partial<typeof arenaRoundPlayer.$inferSelect>,
  meta: Meta,
): Promise<void> {
  const id = `${round}-${tokenId}`;
  const current = (await context.db.find(arenaRoundPlayer, { id })) ?? {
    id,
    round,
    tokenId,
    seat: 0,
    charged: 0n,
    rank: null,
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
    round?: number;
    tokenId?: bigint;
    account?: `0x${string}`;
    amount?: bigint;
    ref?: bigint;
    needsFunds?: boolean;
  },
): Promise<void> {
  await context.db.insert(arenaEvent).values({
    id: `${meta.blockNumber}-${meta.logIndex}`,
    kind: row.kind,
    round: row.round ?? null,
    tokenId: row.tokenId ?? null,
    account: row.account ?? null,
    amount: row.amount ?? null,
    ref: row.ref ?? null,
    needsFunds: row.needsFunds ?? null,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
    logIndex: meta.logIndex,
  });
}

if (process.env.PONDER_ARENA_STORAGE_ADDRESS) {
  // ── Balances ──

  // addBalance: a top-up from a wallet.
  ponder.on("NormiesArenaStorage:Deposited", async ({ event, context }) => {
    const { id, from, amount } = event.args;
    const meta = metaOf(event);
    await patchNormie(context, id, (n) => ({ balance: n.balance + amount, deposited: n.deposited + amount }), meta);
    await patchStats(
      context,
      (s) => ({ totalAllocated: s.totalAllocated + amount, pixelsDeposited: s.pixelsDeposited + amount }),
      meta,
    );
    await logEvent(context, meta, { kind: "deposit", tokenId: id, account: from, amount });
  });

  // withdraw: paid to the Normie's holder.
  ponder.on("NormiesArenaStorage:Withdrawn", async ({ event, context }) => {
    const { id, to, amount } = event.args;
    const meta = metaOf(event);
    await patchNormie(context, id, (n) => ({ balance: n.balance - amount, withdrawn: n.withdrawn + amount }), meta);
    await patchStats(
      context,
      (s) => ({ totalAllocated: s.totalAllocated - amount, pixelsWithdrawn: s.pixelsWithdrawn + amount }),
      meta,
    );
    await logEvent(context, meta, { kind: "withdraw", tokenId: id, account: to, amount });
  });

  // rescue: a burned Normie's whole balance leaves.
  ponder.on("NormiesArenaStorage:Rescued", async ({ event, context }) => {
    const { id, to, amount } = event.args;
    const meta = metaOf(event);
    await patchNormie(context, id, (n) => ({ balance: n.balance - amount }), meta);
    await patchStats(context, (s) => ({ totalAllocated: s.totalAllocated - amount }), meta);
    await logEvent(context, meta, { kind: "rescue", tokenId: id, account: to, amount });
  });

  // chargeEntry: balance -> the round's pool. Emitted just before Admitted for the same Normie.
  ponder.on("NormiesArenaStorage:Charged", async ({ event, context }) => {
    const { id, amount } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    await patchNormie(
      context,
      id,
      (n) => ({ balance: n.balance - amount, pixelsCharged: n.pixelsCharged + amount }),
      meta,
    );
    await patchRound(context, round, (r) => ({ fees: r.fees + amount, unpaid: r.unpaid + amount }), meta);
    await patchPlayer(context, round, id, (p) => ({ charged: p.charged + amount }), meta);
    await patchStats(
      context,
      (s) => ({ totalAllocated: s.totalAllocated - amount, totalPooled: s.totalPooled + amount }),
      meta,
    );
    await logEvent(context, meta, { kind: "entry", round, tokenId: id, amount });
  });

  // creditFromPool: the round's pool -> balance, as a prize (settle) or a refund (cancel). Which one is only
  // known when Settled or Cancelled follows in the same transaction, so the credit waits on the round row.
  ponder.on("NormiesArenaStorage:Credited", async ({ event, context }) => {
    const { id, amount } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    await patchNormie(context, id, (n) => ({ balance: n.balance + amount }), meta);
    await patchRound(
      context,
      round,
      (r) => ({
        unpaid: r.unpaid - amount,
        pendingCredits: [...(r.pendingCredits ?? []), { id: Number(id), amount: amount.toString() }],
      }),
      meta,
    );
    await patchStats(
      context,
      (s) => ({ totalAllocated: s.totalAllocated + amount, totalPooled: s.totalPooled - amount }),
      meta,
    );
    await logEvent(context, meta, { kind: "credit", round, tokenId: id, amount });
  });

  // ── Sponsorship ──

  ponder.on("NormiesArenaStorage:Sponsored", async ({ event, context }) => {
    const { from, amount } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    await patchRound(
      context,
      round,
      (r) => ({ sponsorship: r.sponsorship + amount, unpaid: r.unpaid + amount }),
      meta,
    );
    await patchStats(
      context,
      (s) => ({ totalPooled: s.totalPooled + amount, pixelsSponsored: s.pixelsSponsored + amount }),
      meta,
    );
    await logEvent(context, meta, { kind: "sponsor", round, account: from, amount });
  });

  // moveSponsorship: the source keeps its recorded sponsorship and fees, only its unpaid pool drops.
  ponder.on("NormiesArenaStorage:SponsorshipMoved", async ({ event, context }) => {
    const { amount } = event.args;
    const from = Number(event.args.from);
    const to = Number(event.args.to);
    const meta = metaOf(event);
    await patchRound(context, from, (r) => ({ unpaid: r.unpaid - amount, movedOut: r.movedOut + amount }), meta);
    await patchRound(context, to, (r) => ({ sponsorship: r.sponsorship + amount, unpaid: r.unpaid + amount }), meta);
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

  // ── The line ──

  // pushTicket: a new ticket at the back. The Normie's earlier ticket, if any, is dead from here on.
  ponder.on("NormiesArenaStorage:Enrolled", async ({ event, context }) => {
    const { id, ticket } = event.args;
    const meta = metaOf(event);
    const { before } = await patchNormie(context, id, () => ({ ticket, active: true, needsFunds: false }), meta);
    await patchStats(
      context,
      (s) => ({ newestTicket: ticket, inLine: s.inLine + (before.active ? 0 : 1) }),
      meta,
    );
    await logEvent(context, meta, { kind: "enrolled", tokenId: id, ref: ticket });
  });

  // deactivate: out of the line. Can repeat for a Normie already out.
  ponder.on("NormiesArenaStorage:EnrollmentPaused", async ({ event, context }) => {
    const { id, needsFunds } = event.args;
    const meta = metaOf(event);
    const { before } = await patchNormie(context, id, () => ({ active: false, needsFunds }), meta);
    if (before.active) await patchStats(context, (s) => ({ inLine: s.inLine - 1 }), meta);
    await logEvent(context, meta, { kind: "left", tokenId: id, needsFunds });
  });

  ponder.on("NormiesArenaStorage:AgentLinked", async ({ event, context }) => {
    const { id, agentId } = event.args;
    const meta = metaOf(event);
    await patchNormie(context, id, () => ({ agentId }), meta);
    await logEvent(context, meta, { kind: "agent-linked", tokenId: id, ref: agentId });
  });

  // ── Rounds ──

  ponder.on("NormiesArenaStorage:RulesFixed", async ({ event, context }) => {
    const { capacity, price, winnerBps, free } = event.args;
    await patchRound(
      context,
      Number(event.args.round),
      () => ({ capacity: Number(capacity), price, winnerBps: Number(winnerBps), free }),
      metaOf(event),
    );
  });

  ponder.on("NormiesArenaStorage:RoundStarted", async ({ event, context }) => {
    const { ticketCutoff, at } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    await patchRound(
      context,
      round,
      () => ({
        started: true,
        ticketCutoff,
        startedAt: at,
        startedBlock: meta.blockNumber,
        startedTxHash: meta.txHash,
      }),
      meta,
    );
    await patchStats(context, (s) => ({ currentRound: round, roundsStarted: s.roundsStarted + 1 }), meta);
  });

  ponder.on("NormiesArenaStorage:Admitted", async ({ event, context }) => {
    const { id } = event.args;
    const round = Number(event.args.round);
    const meta = metaOf(event);
    const row = await patchRound(context, round, (r) => ({ players: r.players + 1 }), meta);
    await patchPlayer(
      context,
      round,
      id,
      () => ({ seat: row.players, blockNumber: meta.blockNumber, timestamp: meta.timestamp, txHash: meta.txHash }),
      meta,
    );
    await patchNormie(context, id, (n) => ({ roundsPlayed: n.roundsPlayed + 1, lastRound: round }), meta);
    await patchStats(context, (s) => ({ admissions: s.admissions + 1 }), meta);
  });

  ponder.on("NormiesArenaStorage:AdmissionsClosed", async ({ event, context }) => {
    await patchRound(context, Number(event.args.round), () => ({ closed: true }), metaOf(event));
  });

  ponder.on("NormiesArenaStorage:RoundFinished", async ({ event, context }) => {
    const meta = metaOf(event);
    await patchRound(
      context,
      Number(event.args.round),
      () => ({ finished: true, finishedAt: event.args.at, finishedTxHash: meta.txHash }),
      meta,
    );
  });

  // setResultHash: the latest hash replaces any earlier one.
  ponder.on("NormiesArenaStorage:ResultsPosted", async ({ event, context }) => {
    await patchRound(
      context,
      Number(event.args.round),
      () => ({ resultHash: event.args.resultHash }),
      metaOf(event),
    );
  });

  // setSettled: the credits waiting on the round were prizes, in rank order (best first).
  ponder.on("NormiesArenaStorage:Settled", async ({ event, context }) => {
    const round = Number(event.args.round);
    const meta = metaOf(event);
    const current = await context.db.find(arenaRound, { round });
    const credits = current?.pendingCredits ?? [];
    let paid = 0n;
    for (const [i, credit] of credits.entries()) {
      const tokenId = BigInt(credit.id);
      const amount = BigInt(credit.amount);
      paid += amount;
      await patchPlayer(context, round, tokenId, () => ({ rank: i + 1, prize: amount }), meta);
      await patchNormie(context, tokenId, (n) => ({ wins: n.wins + 1, pixelsWon: n.pixelsWon + amount }), meta);
    }
    await patchRound(
      context,
      round,
      (r) => ({
        settled: true,
        resultHash: event.args.resultHash,
        winners: credits.length,
        paid: r.paid + paid,
        pendingCredits: null,
        endedAt: meta.timestamp,
        endedTxHash: meta.txHash,
      }),
      meta,
    );
    await patchStats(
      context,
      (s) => ({ roundsSettled: s.roundsSettled + 1, pixelsPaid: s.pixelsPaid + paid }),
      meta,
    );
  });

  // setCancelled: the credits waiting on the round were entry refunds; the sponsorship moved to `carriedTo`
  // (its SponsorshipMoved event came just before). Admissions close with it.
  ponder.on("NormiesArenaStorage:Cancelled", async ({ event, context }) => {
    const round = Number(event.args.round);
    const meta = metaOf(event);
    const current = await context.db.find(arenaRound, { round });
    const credits = current?.pendingCredits ?? [];
    let refunded = 0n;
    for (const credit of credits) {
      const tokenId = BigInt(credit.id);
      const amount = BigInt(credit.amount);
      refunded += amount;
      await patchPlayer(context, round, tokenId, () => ({ refund: amount }), meta);
      await patchNormie(context, tokenId, (n) => ({ pixelsRefunded: n.pixelsRefunded + amount }), meta);
    }
    await patchRound(
      context,
      round,
      (r) => ({
        cancelled: true,
        closed: true,
        refunded: r.refunded + refunded,
        carriedTo: Number(event.args.carriedTo),
        pendingCredits: null,
        endedAt: meta.timestamp,
        endedTxHash: meta.txHash,
      }),
      meta,
    );
    await patchStats(context, (s) => ({ roundsCancelled: s.roundsCancelled + 1 }), meta);
  });

  // ── Skins ──

  ponder.on("NormiesArenaStorage:SkinPurchased", async ({ event, context }) => {
    const { purchaseId, id, buyer, price } = event.args;
    const meta = metaOf(event);
    await context.db.insert(arenaSkinPurchase).values({
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
}

import { ponder } from "ponder:registry";
import { revshareClaim, revshareEpoch, revshareRelease, revshareStats } from "ponder:schema";
import { eventMeta, type EventMeta, type IndexingContext } from "./lib/canvas-state.js";

// ──────────────────────────────────────────────
//  Revenue share: epochs posted to NormiesRevenuePool, claims against them,
//  and royalties the splitter forwarded. Payout tables and proofs are not on
//  chain; the API serves them from the published epoch files.
// ──────────────────────────────────────────────

const GLOBAL_ID = "global";

async function patchStats(
  context: IndexingContext,
  delta: { epochs?: number; allocated?: bigint; claimed?: bigint; swept?: bigint; royalties?: bigint },
  meta: EventMeta,
): Promise<void> {
  const existing = await context.db.find(revshareStats, { id: GLOBAL_ID });
  const next = {
    id: GLOBAL_ID,
    epochs: (existing?.epochs ?? 0) + (delta.epochs ?? 0),
    allocatedWei: (existing?.allocatedWei ?? 0n) + (delta.allocated ?? 0n),
    claimedWei: (existing?.claimedWei ?? 0n) + (delta.claimed ?? 0n),
    sweptWei: (existing?.sweptWei ?? 0n) + (delta.swept ?? 0n),
    royaltiesToPoolWei: (existing?.royaltiesToPoolWei ?? 0n) + (delta.royalties ?? 0n),
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
  };
  await context.db.insert(revshareStats).values(next).onConflictDoUpdate({
    epochs: next.epochs,
    allocatedWei: next.allocatedWei,
    claimedWei: next.claimedWei,
    sweptWei: next.sweptWei,
    royaltiesToPoolWei: next.royaltiesToPoolWei,
    blockNumber: next.blockNumber,
    timestamp: next.timestamp,
  });
}

ponder.on("NormiesRevenuePool:EpochPosted", async ({ event, context }) => {
  const { epochId, root, amount, fromBlock, toBlock, claimableAt, sweepableAt, configHash, dataURI } = event.args;
  const meta = eventMeta(event);
  await context.db.insert(revshareEpoch).values({
    epochId,
    root,
    amount,
    claimed: 0n,
    claims: 0,
    fromBlock,
    toBlock,
    claimableAt,
    sweepableAt,
    configHash,
    dataURI,
    status: "posted",
    sweptAmount: null,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
  });
  await patchStats(context, { epochs: 1, allocated: amount }, meta);
});

ponder.on("NormiesRevenuePool:Claimed", async ({ event, context }) => {
  const { epochId, index, account, amount } = event.args;
  const meta = eventMeta(event);
  await context.db.insert(revshareClaim).values({
    id: `${epochId}-${index}`,
    epochId,
    index,
    account,
    amount,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
  });
  await context.db
    .update(revshareEpoch, { epochId })
    .set((row) => ({ claimed: row.claimed + amount, claims: row.claims + 1 }));
  await patchStats(context, { claimed: amount }, meta);
});

ponder.on("NormiesRevenuePool:Swept", async ({ event, context }) => {
  const { epochId, returnedToPool } = event.args;
  const meta = eventMeta(event);
  await context.db.update(revshareEpoch, { epochId }).set({ status: "swept", sweptAmount: returnedToPool });
  await patchStats(context, { swept: returnedToPool }, meta);
});

// Cancelled before it opened: nothing was ever claimable, so the epoch no longer counts as allocated. The API only
// offers claims on "posted" epochs, so a cancelled one simply drops out of every wallet's list.
ponder.on("NormiesRevenuePool:EpochCancelled", async ({ event, context }) => {
  const { epochId, returnedToPool } = event.args;
  const meta = eventMeta(event);
  await context.db.update(revshareEpoch, { epochId }).set({ status: "cancelled" });
  await patchStats(context, { allocated: -returnedToPool }, meta);
});

ponder.on("NormiesRoyaltySplitter:Released", async ({ event, context }) => {
  const { toPool, toTeam } = event.args;
  const meta = eventMeta(event);
  await context.db.insert(revshareRelease).values({
    id: `${event.block.number}-${event.log.logIndex}`,
    toPool,
    toTeam,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
  });
  await patchStats(context, { royalties: toPool }, meta);
});

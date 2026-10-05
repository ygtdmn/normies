import { Hono } from "hono";
import { REVSHARE_ENABLED } from "../config.js";
import { REVSHARE_CONFIG, configHash } from "../revshare/index.js";
import { boostPct, bracket100 } from "../revshare/index.js";
import {
    getClaims,
    getEpoch,
    getEpochs,
    getLiveScores,
    getPoolStatus,
    loadEpochFile,
} from "../services/revshare-data.js";

const revshare = new Hono();
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

revshare.use("*", async (c, next) => {
    if (!REVSHARE_ENABLED) return c.json({ error: "Revenue share is not enabled" }, 404);
    await next();
});

/** The scoring rules. The site reads them from here so its calculator can never drift from the payouts. */
revshare.get("/config", (c) => c.json({ config: REVSHARE_CONFIG, configHash: configHash() }));

revshare.get("/status", async (c) => {
    try {
        return c.json(await getPoolStatus());
    } catch (err) {
        return c.json({ error: err instanceof Error ? err.message : "Pool status unavailable" }, 502);
    }
});

revshare.get("/epochs", async (c) => {
    const { epochs } = await getEpochs();
    const files = await Promise.all(epochs.map((e) => loadEpochFile(e.epochId)));
    return c.json({ epochs: epochs.map((e, i) => ({ ...e, published: files[i] !== null })) });
});

revshare.get("/epochs/:id", async (c) => {
    const id = c.req.param("id");
    if (!/^\d+$/.test(id)) return c.json({ error: "Invalid epoch id" }, 400);
    let epoch;
    try {
        epoch = await getEpoch(id);
    } catch {
        return c.json({ error: "Epoch not found" }, 404);
    }
    const file = await loadEpochFile(id);
    return c.json({
        ...epoch,
        published: file !== null,
        // The payout table can be large; proofs are served per address.
        file: file
            ? { total: file.total, sampleBlocks: file.sampleBlocks, excluded: file.excluded, payouts: file.leaves.length, rootMatches: file.root === epoch.root }
            : null,
    });
});

/** The raw epoch file (payouts and proofs): the on-chain dataURI, so anyone can check it with `pnpm revshare verify <url>`. */
revshare.get("/files/:name", async (c) => {
    const match = /^(\d+)\.json$/.exec(c.req.param("name"));
    if (!match) return c.json({ error: "Expected <epochId>.json" }, 400);
    const file = await loadEpochFile(match[1]);
    if (!file) return c.json({ error: "Epoch file not published" }, 404);
    c.header("Cache-Control", "public, max-age=60");
    return c.json(file);
});

revshare.get("/epochs/:id/proof/:address", async (c) => {
    const id = c.req.param("id");
    const address = c.req.param("address").toLowerCase();
    if (!ADDRESS_RE.test(address)) return c.json({ error: "Invalid address" }, 400);
    const file = await loadEpochFile(id);
    if (!file) return c.json({ error: "Epoch file not published" }, 404);
    const leaf = file.leaves.find((l) => l.account.toLowerCase() === address);
    if (!leaf) return c.json({ error: "No payout for this address in this epoch" }, 404);
    return c.json({ epochId: file.epochId, root: file.root, ...leaf });
});

/**
 * A wallet's live standing (a projection from the indexer, not a payout), what it can claim right now with the
 * proofs to do it, and what it has claimed before.
 */
revshare.get("/wallet/:address", async (c) => {
    const address = c.req.param("address").toLowerCase();
    if (!ADDRESS_RE.test(address)) return c.json({ error: "Invalid address" }, 400);

    const [scores, { epochs }, { claims }] = await Promise.all([getLiveScores(), getEpochs(), getClaims(address)]);
    const entry = scores.wallets.get(address);
    const claimedEpochs = new Set(claims.map((cl) => cl.epochId));
    const now = Math.floor(Date.now() / 1000);

    const claimable = [];
    for (const epoch of epochs) {
        if (epoch.status !== "posted" || claimedEpochs.has(epoch.epochId)) continue;
        const file = await loadEpochFile(epoch.epochId);
        if (!file || file.root !== epoch.root) continue;
        const leaf = file.leaves.find((l) => l.account.toLowerCase() === address);
        if (!leaf) continue;
        claimable.push({
            epochId: epoch.epochId,
            index: leaf.index,
            amount: leaf.amount,
            proof: leaf.proof,
            claimableAt: epoch.claimableAt,
            sweepableAt: epoch.sweepableAt,
            open: Number(epoch.claimableAt) <= now,
        });
    }

    const b = entry?.breakdown;
    return c.json({
        address,
        score: b ? b.score.toString() : "0",
        totalScore: scores.totalScore.toString(),
        // Parts per million, so clients need no bigint maths for a percentage.
        sharePpm: b && scores.totalScore > 0n ? Number((b.score * 1_000_000n) / scores.totalScore) : 0,
        breakdown: b
            ? {
                  tokens: b.tokens,
                  bracket100: b.bracket100,
                  pixels: b.pixels.toString(),
                  boostPct: b.boostPct,
                  normiePoints: b.normiePoints.toString(),
                  pixelPoints: b.pixelPoints.toString(),
              }
            : null,
        claimable,
        claimableWei: claimable.filter((cl) => cl.open).reduce((sum, cl) => sum + BigInt(cl.amount), 0n).toString(),
        claims,
        computedAt: scores.at,
    });
});

/** How many scoring wallets sit in each cell of the tier grid: Normie bracket x pixel boost. */
revshare.get("/tiers", async (c) => {
    const scores = await getLiveScores();
    const rows = REVSHARE_CONFIG.brackets.map(([min, x100]) => ({ minTokens: min, bracket100: x100 }));
    const cols = [{ minPixels: 0, boostPct: 0 }, ...REVSHARE_CONFIG.boost.map(([min, pct]) => ({ minPixels: min, boostPct: pct }))];
    const grid = rows.map(() => cols.map(() => 0));
    for (const { breakdown } of scores.wallets.values()) {
        if (breakdown.tokens < 1) continue;
        const bracket = bracket100(breakdown.tokens);
        const boost = boostPct(breakdown.pixels, breakdown.tokens);
        const r = rows.findIndex((row) => row.bracket100 === bracket);
        const cIdx = cols.findIndex((col) => col.boostPct === boost);
        if (r >= 0 && cIdx >= 0) grid[r][cIdx] += 1;
    }
    return c.json({ rows, cols, wallets: grid, scoringWallets: scores.wallets.size, totalScore: scores.totalScore.toString(), computedAt: scores.at });
});

export { revshare };

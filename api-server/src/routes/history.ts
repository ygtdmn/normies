import { Hono } from "hono";
import { hexToBytes } from "viem";
import { parseTokenId, queryInt } from "../lib/validation.js";
import { imageDataToPixelString } from "../lib/pixels.js";
import { renderSvg } from "../lib/svg.js";
import { svgToPng } from "../lib/png.js";
import { countPixels } from "../lib/traits.js";
import { composite, emptyBitmap, fitToGrid } from "../lib/bitmap.js";
import { getImageData } from "../services/token-data.js";
import { getBaseImageDataAtBlock, getZombieInfo } from "../services/zombie-data.js";
import { getBaseClearedBlock } from "../services/canvas-data.js";
import {
    getBurns,
    getBurnCommitment,
    getBurnsForAddress,
    getBurnsForReceiver,
    getBurnedTokens,
    getBurnedTokenIds,
    getBurnedToken,
    getPendingLegacyBurns,
    getTransformHistory,
    getTransformVersion,
    getCustomizedEvents,
    getStats,
    isPonderNotFound,
    type TransformData,
} from "../services/ponder-data.js";

const history = new Hono();

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
    const limit = queryInt(c.req.query("limit"), 50, 1, 100);
    const offset = queryInt(c.req.query("offset"), 0, 0);
    return { limit, offset };
}

function parseTimestampQuery(c: { req: { query: (key: string) => string | undefined } }) {
    const raw = c.req.query("after_timestamp") ?? c.req.query("since_timestamp");
    if (raw === undefined) return {};
    try {
        const timestamp = BigInt(raw);
        if (timestamp < 0n) throw new Error("negative timestamp");
        return { timestamp };
    } catch {
        return { error: "`after_timestamp` must be a non-negative unix timestamp string" };
    }
}

/**
 * Rebuilds the image of one overlay version: the base art as it stood at that
 * block (zombie or original), embedded into the version's grid, dropped when
 * the base had already been cleared, with the version's overlay on top. A
 * cleared version has no overlay and shows the base alone.
 */
async function compositeVersion(tokenId: number, transform: TransformData): Promise<Uint8Array> {
    const gridSize = transform.gridSize ?? 40;
    const block = BigInt(transform.blockNumber);
    const [rawBase, clearedAt] = await Promise.all([
        getBaseImageDataAtBlock(tokenId, block),
        getBaseClearedBlock(tokenId),
    ]);
    const base = clearedAt !== null && block >= clearedAt ? emptyBitmap(gridSize) : fitToGrid(rawBase, gridSize);
    if (transform.cleared || !transform.transformBitmap) return base;
    return composite(base, fitToGrid(hexToBytes(transform.transformBitmap as `0x${string}`), gridSize));
}

function parseVersionQuery(c: { req: { query: (key: string) => string | undefined } }): 1 | 2 | undefined | { error: string } {
    const raw = c.req.query("version");
    if (raw === undefined) return undefined;
    if (raw === "1") return 1;
    if (raw === "2") return 2;
    return { error: "version must be 1 or 2" };
}

// ──────────────────────────────────────────────
//  Burns: Commitments
// ──────────────────────────────────────────────

history.get("/burns", async (c) => {
    const { limit, offset } = parsePagination(c);
    const burns = await getBurns(limit, offset);
    return c.json(burns);
});

// Original-canvas commitments not yet revealed there. They must all be revealed (anyone can)
// before that canvas is paused for the cutover.
history.get("/burns/pending/legacy", async (c) => {
    const { limit, offset } = parsePagination(c);
    const owner = c.req.query("owner");
    if (owner !== undefined && !/^0x[0-9a-fA-F]{40}$/.test(owner)) {
        return c.json({ error: "Invalid owner address" }, 400);
    }
    return c.json(await getPendingLegacyBurns(owner, limit, offset));
});

// Both canvases' commitments. Commit ids restart at 0 on the V2 canvas, so a bare number is
// ambiguous: `1-538` names one exactly (the `id` every burns list returns), `?version=1|2` picks
// a canvas, and a bare number alone tries the newest canvas first, then the older one. Only an
// id that is on neither canvas is a 404.
const COMMIT_ID = /^(?:([12])-)?(\d{1,12})$/;
const BURN_VERSIONS = [2, 1] as const;

history.get("/burns/:commitId", async (c) => {
    const match = COMMIT_ID.exec(c.req.param("commitId"));
    if (!match) return c.json({ error: "commitId must be a number, or <version>-<number> like 1-538" }, 400);
    const query = parseVersionQuery(c);
    if (query && typeof query === "object") return c.json(query, 400);
    const named = match[1] ? (Number(match[1]) as 1 | 2) : undefined;
    if (named && query && named !== query) return c.json({ error: `${match[0]} is a V${named} commitment, but version=${query}` }, 400);
    const commitId = match[2];

    const pinned = named ?? query;
    if (pinned) return c.json(await getBurnCommitment(commitId, pinned));
    for (const version of BURN_VERSIONS) {
        try {
            return c.json(await getBurnCommitment(commitId, version));
        } catch (err) {
            if (!isPonderNotFound(err)) throw err;
        }
    }
    return c.json({ error: "No burn commitment with that id on either canvas" }, 404);
});

history.get("/burns/address/:address", async (c) => {
    const { limit, offset } = parsePagination(c);
    const burns = await getBurnsForAddress(c.req.param("address"), limit, offset);
    return c.json(burns);
});

history.get("/burns/receiver/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const { limit, offset } = parsePagination(c);
    const burns = await getBurnsForReceiver(result.tokenId, limit, offset);
    return c.json(burns);
});

// ──────────────────────────────────────────────
//  Burns: Individual Burned Tokens
// ──────────────────────────────────────────────

history.get("/burned-tokens", async (c) => {
    const { limit, offset } = parsePagination(c);
    const tokens = await getBurnedTokens(limit, offset);
    return c.json(tokens);
});

// Every burned token id in one response: { count, ids } (ascending). The site's collection wall
// reads it instead of paging /burned-tokens.
history.get("/burned-ids", async (c) => {
    return c.json(await getBurnedTokenIds());
});

history.get("/burned/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const burnInfo = await getBurnedToken(result.tokenId);
    return c.json(burnInfo);
});

history.get("/burned/:tokenId/image.svg", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    // SSTORE2 data persists after burn — original image is still readable
    const imageData = await getImageData(result.tokenId);
    const svg = renderSvg(imageData);
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

history.get("/burned/:tokenId/image.png", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const imageData = await getImageData(result.tokenId);
    const svg = renderSvg(imageData);
    const png = svgToPng(svg);
    return new Response(png, { status: 200, headers: { "Content-Type": "image/png" } });
});

// ──────────────────────────────────────────────
//  Transform History
// ──────────────────────────────────────────────

history.get("/customized", async (c) => {
    const { limit, offset } = parsePagination(c);
    const timestampResult = parseTimestampQuery(c);
    if ("error" in timestampResult) return c.json({ error: timestampResult.error }, 400);

    const sortRaw = c.req.query("sort");
    const sort = sortRaw === "asc" || sortRaw === "desc"
        ? sortRaw
        : timestampResult.timestamp !== undefined
            ? "asc"
            : "desc";

    return c.json(await getCustomizedEvents({
        limit,
        offset,
        afterTimestamp: timestampResult.timestamp,
        sort,
    }));
});

history.get("/normie/:id/versions", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const { limit, offset } = parsePagination(c);
    // `pixels=1` adds each version's composited art (the /version/:v/pixels string). It is already
    // computed for newPixelCount, and it lets a history strip draw every thumbnail from this one
    // response instead of one image request per version against the per-IP rate limit.
    const withPixels = c.req.query("pixels") === "1";
    // Versions are numbered oldest-first (0 = first overlay ever written), so
    // `version` here is exactly what /version/:version/* accepts.
    const transforms = await getTransformHistory(result.tokenId, limit, offset, true);
    // Warm the zombie-info cache once so the per-version base lookups below
    // share a single fetch instead of racing cold-cache reads under Promise.all.
    await getZombieInfo(result.tokenId).catch(() => {});
    const versions = await Promise.all(
        transforms.map(async (t, i) => {
            const art = t.transformBitmap || t.cleared ? await compositeVersion(result.tokenId, t) : null;
            return {
                version: offset + i,
                changeCount: t.changeCount,
                // The on-chain `newPixelCount` is counted against the original mint
                // art even for zombies; recount against the active (zombie/era) base
                // so the figure matches the actually-rendered image for this version.
                newPixelCount: art ? countPixels(art) : t.newPixelCount,
                gridSize: t.gridSize ?? 40,
                cleared: t.cleared ?? false,
                transformer: t.transformer,
                blockNumber: t.blockNumber,
                timestamp: t.timestamp,
                txHash: t.txHash,
                ...(withPixels && art ? { pixels: imageDataToPixelString(art) } : {}),
            };
        }),
    );
    return c.json(versions);
});

history.get("/normie/:id/version/:version/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const version = Number(c.req.param("version"));

    const transform = await getTransformVersion(result.tokenId, version);
    if (!transform.transformBitmap && !transform.cleared) {
        return c.json({ error: "Transform bitmap not available for this version" }, 404);
    }

    const pixels = imageDataToPixelString(await compositeVersion(result.tokenId, transform));
    return c.text(pixels);
});

history.get("/normie/:id/version/:version/image.svg", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const version = Number(c.req.param("version"));

    const transform = await getTransformVersion(result.tokenId, version);
    if (!transform.transformBitmap && !transform.cleared) {
        return c.json({ error: "Transform bitmap not available for this version" }, 404);
    }

    const svg = renderSvg(await compositeVersion(result.tokenId, transform));
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

history.get("/normie/:id/version/:version/image.png", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const version = Number(c.req.param("version"));

    const transform = await getTransformVersion(result.tokenId, version);
    if (!transform.transformBitmap && !transform.cleared) {
        return c.json({ error: "Transform bitmap not available for this version" }, 404);
    }

    const svg = renderSvg(await compositeVersion(result.tokenId, transform));
    const png = svgToPng(svg);
    return new Response(png, { status: 200, headers: { "Content-Type": "image/png" } });
});

// ──────────────────────────────────────────────
//  Stats
// ──────────────────────────────────────────────

history.get("/stats", async (c) => {
    const stats = await getStats();
    return c.json(stats);
});

export { history };

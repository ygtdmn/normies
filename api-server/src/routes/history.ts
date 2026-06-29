import { Hono } from "hono";
import { hexToBytes } from "viem";
import { parseTokenId } from "../lib/validation.js";
import { imageDataToPixelString } from "../lib/pixels.js";
import { renderSvg } from "../lib/svg.js";
import { svgToPng } from "../lib/png.js";
import { countPixels } from "../lib/traits.js";
import { getImageData } from "../services/token-data.js";
import { getBaseImageDataAtBlock, getZombieInfo } from "../services/zombie-data.js";
import {
    getBurns,
    getBurnCommitment,
    getBurnsForAddress,
    getBurnsForReceiver,
    getBurnedTokens,
    getBurnedToken,
    getTransformHistory,
    getTransformVersion,
    getCustomizedEvents,
    getStats,
} from "../services/ponder-data.js";

const history = new Hono();

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50), 1), 100);
    const offset = Math.max(Number(c.req.query("offset") ?? 0), 0);
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

function compositeBuffers(original: Uint8Array, transform: Uint8Array): Uint8Array {
    const result = new Uint8Array(200);
    for (let i = 0; i < 200; i++) {
        result[i] = original[i] ^ transform[i];
    }
    return result;
}

// ──────────────────────────────────────────────
//  Burns: Commitments
// ──────────────────────────────────────────────

history.get("/burns", async (c) => {
    const { limit, offset } = parsePagination(c);
    const burns = await getBurns(limit, offset);
    return c.json(burns);
});

history.get("/burns/:commitId", async (c) => {
    const commitment = await getBurnCommitment(c.req.param("commitId"));
    return c.json(commitment);
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
    const transforms = await getTransformHistory(result.tokenId, limit, offset, true);
    // Warm the zombie-info cache once so the per-version base lookups below
    // share a single fetch instead of racing cold-cache reads under Promise.all.
    await getZombieInfo(result.tokenId).catch(() => {});
    const versions = await Promise.all(
        transforms.map(async (t, i) => ({
            version: offset + i,
            changeCount: t.changeCount,
            // The on-chain `newPixelCount` is counted against the original mint
            // art even for zombies; recount against the active (zombie/era) base
            // so the figure matches the actually-rendered image for this version.
            newPixelCount: t.transformBitmap
                ? countPixels(
                    compositeBuffers(
                        await getBaseImageDataAtBlock(result.tokenId, BigInt(t.blockNumber)),
                        hexToBytes(t.transformBitmap as `0x${string}`),
                    ),
                )
                : t.newPixelCount,
            transformer: t.transformer,
            blockNumber: t.blockNumber,
            timestamp: t.timestamp,
            txHash: t.txHash,
        })),
    );
    return c.json(versions);
});

history.get("/normie/:id/version/:version/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const version = Number(c.req.param("version"));

    const transform = await getTransformVersion(result.tokenId, version);
    if (!transform.transformBitmap) {
        return c.json({ error: "Transform bitmap not available for this version" }, 404);
    }

    const base = await getBaseImageDataAtBlock(result.tokenId, BigInt(transform.blockNumber));
    const transformBytes = hexToBytes(transform.transformBitmap as `0x${string}`);
    const composited = compositeBuffers(base, transformBytes);
    const pixels = imageDataToPixelString(composited);
    return c.text(pixels);
});

history.get("/normie/:id/version/:version/image.svg", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const version = Number(c.req.param("version"));

    const transform = await getTransformVersion(result.tokenId, version);
    if (!transform.transformBitmap) {
        return c.json({ error: "Transform bitmap not available for this version" }, 404);
    }

    const base = await getBaseImageDataAtBlock(result.tokenId, BigInt(transform.blockNumber));
    const transformBytes = hexToBytes(transform.transformBitmap as `0x${string}`);
    const composited = compositeBuffers(base, transformBytes);
    const svg = renderSvg(composited);
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

history.get("/normie/:id/version/:version/image.png", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const version = Number(c.req.param("version"));

    const transform = await getTransformVersion(result.tokenId, version);
    if (!transform.transformBitmap) {
        return c.json({ error: "Transform bitmap not available for this version" }, 404);
    }

    const base = await getBaseImageDataAtBlock(result.tokenId, BigInt(transform.blockNumber));
    const transformBytes = hexToBytes(transform.transformBitmap as `0x${string}`);
    const composited = compositeBuffers(base, transformBytes);
    const svg = renderSvg(composited);
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

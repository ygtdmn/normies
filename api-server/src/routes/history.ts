import { Hono } from "hono";
import { hexToBytes } from "viem";
import { parseTokenId } from "../lib/validation.js";
import { imageDataToPixelString } from "../lib/pixels.js";
import { renderSvg } from "../lib/svg.js";
import { svgToPng } from "../lib/png.js";
import { getImageData } from "../services/token-data.js";
import { PONDER_ENABLED } from "../config.js";
import {
    getBurns,
    getBurnCommitment,
    getBurnsForAddress,
    getBurnsForReceiver,
    getBurnedTokens,
    getBurnedToken,
    getTransformHistory,
    getTransformVersion,
    getStats,
} from "../services/ponder-data.js";

const history = new Hono();

function requirePonder(c: { json: (data: unknown, status: number) => Response }) {
    if (!PONDER_ENABLED) {
        return c.json({ error: "History features require PONDER_API_URL to be configured" }, 503);
    }
    return null;
}

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50), 1), 100);
    const offset = Math.max(Number(c.req.query("offset") ?? 0), 0);
    return { limit, offset };
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
    const check = requirePonder(c);
    if (check) return check;
    const { limit, offset } = parsePagination(c);
    const burns = await getBurns(limit, offset);
    return c.json(burns);
});

history.get("/burns/:commitId", async (c) => {
    const check = requirePonder(c);
    if (check) return check;
    const commitment = await getBurnCommitment(c.req.param("commitId"));
    return c.json(commitment);
});

history.get("/burns/address/:address", async (c) => {
    const check = requirePonder(c);
    if (check) return check;
    const { limit, offset } = parsePagination(c);
    const burns = await getBurnsForAddress(c.req.param("address"), limit, offset);
    return c.json(burns);
});

history.get("/burns/receiver/:tokenId", async (c) => {
    const check = requirePonder(c);
    if (check) return check;
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
    const check = requirePonder(c);
    if (check) return check;
    const { limit, offset } = parsePagination(c);
    const tokens = await getBurnedTokens(limit, offset);
    return c.json(tokens);
});

history.get("/burned/:tokenId", async (c) => {
    const check = requirePonder(c);
    if (check) return check;
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

history.get("/normie/:id/versions", async (c) => {
    const check = requirePonder(c);
    if (check) return check;
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const { limit, offset } = parsePagination(c);
    const transforms = await getTransformHistory(result.tokenId, limit, offset);
    return c.json(
        transforms.map((t, i) => ({
            version: offset + i,
            changeCount: t.changeCount,
            newPixelCount: t.newPixelCount,
            transformer: t.transformer,
            blockNumber: t.blockNumber,
            timestamp: t.timestamp,
            txHash: t.txHash,
        })),
    );
});

history.get("/normie/:id/version/:version/pixels", async (c) => {
    const check = requirePonder(c);
    if (check) return check;
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const version = Number(c.req.param("version"));

    const transform = await getTransformVersion(result.tokenId, version);
    if (!transform.transformBitmap) {
        return c.json({ error: "Transform bitmap not available for this version" }, 404);
    }

    const original = await getImageData(result.tokenId);
    const transformBytes = hexToBytes(transform.transformBitmap as `0x${string}`);
    const composited = compositeBuffers(original, transformBytes);
    const pixels = imageDataToPixelString(composited);
    return c.text(pixels);
});

history.get("/normie/:id/version/:version/image.svg", async (c) => {
    const check = requirePonder(c);
    if (check) return check;
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const version = Number(c.req.param("version"));

    const transform = await getTransformVersion(result.tokenId, version);
    if (!transform.transformBitmap) {
        return c.json({ error: "Transform bitmap not available for this version" }, 404);
    }

    const original = await getImageData(result.tokenId);
    const transformBytes = hexToBytes(transform.transformBitmap as `0x${string}`);
    const composited = compositeBuffers(original, transformBytes);
    const svg = renderSvg(composited);
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

history.get("/normie/:id/version/:version/image.png", async (c) => {
    const check = requirePonder(c);
    if (check) return check;
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const version = Number(c.req.param("version"));

    const transform = await getTransformVersion(result.tokenId, version);
    if (!transform.transformBitmap) {
        return c.json({ error: "Transform bitmap not available for this version" }, 404);
    }

    const original = await getImageData(result.tokenId);
    const transformBytes = hexToBytes(transform.transformBitmap as `0x${string}`);
    const composited = compositeBuffers(original, transformBytes);
    const svg = renderSvg(composited);
    const png = svgToPng(svg);
    return new Response(png, { status: 200, headers: { "Content-Type": "image/png" } });
});

// ──────────────────────────────────────────────
//  Stats
// ──────────────────────────────────────────────

history.get("/stats", async (c) => {
    const check = requirePonder(c);
    if (check) return check;
    const stats = await getStats();
    return c.json(stats);
});

export { history };

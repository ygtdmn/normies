import { Hono } from "hono";
import { getCanvasInfo, getCanvasStatus } from "../services/canvas-data.js";
import { getCanvasSinks, getTokenPixelActivity } from "../services/pixel-market-data.js";
import { parseTokenId, queryInt } from "../lib/validation.js";
import { CANVAS_ENABLED, PIXEL_MARKET_ENABLED } from "../config.js";

const canvas = new Hono();

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
    const limit = queryInt(c.req.query("limit"), 50, 1, 100);
    const offset = queryInt(c.req.query("offset"), 0, 0);
    return { limit, offset };
}

canvas.get("/status", async (c) => {
    if (!CANVAS_ENABLED) {
        return c.json({ error: "Canvas features are not enabled" }, 404);
    }
    const status = await getCanvasStatus();
    return c.json(status);
});

// Pixels attached to a token, split into locked (backing the overlay) and free
// (withdrawable without a reset), plus the grid size and blank-canvas flag.
canvas.get("/token/:id/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const info = await getCanvasInfo(result.tokenId);
    return c.json({
        tokenId: result.tokenId,
        attached: info.actionPoints,
        locked: info.lockedPixels,
        free: info.freePixels,
        level: info.level,
        gridSize: info.gridSize,
        baseCleared: info.baseCleared,
        migrated: info.migrated,
        customized: info.customized,
    });
});

canvas.get("/token/:id/activity", async (c) => {
    if (!PIXEL_MARKET_ENABLED) return c.json({ error: "Pixel Market features are not enabled" }, 404);
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const { limit, offset } = parsePagination(c);
    return c.json(await getTokenPixelActivity(result.tokenId, limit, offset));
});

// Pixels spent on canvas services: enlargements and blank canvases.
canvas.get("/sinks", async (c) => {
    if (!PIXEL_MARKET_ENABLED) return c.json({ error: "Pixel Market features are not enabled" }, 404);
    const { limit, offset } = parsePagination(c);
    const tokenIdRaw = c.req.query("tokenId");
    let tokenId: number | undefined;
    if (tokenIdRaw !== undefined) {
        const parsed = parseTokenId(tokenIdRaw);
        if ("error" in parsed) return c.json({ error: parsed.error }, 400);
        tokenId = parsed.tokenId;
    }
    const kindRaw = c.req.query("kind");
    const kind = kindRaw === "enlarge" || kindRaw === "clearBase" ? kindRaw : undefined;
    return c.json(await getCanvasSinks({ tokenId, kind, limit, offset }));
});

export { canvas };

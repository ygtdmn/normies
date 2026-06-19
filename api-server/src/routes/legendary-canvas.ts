import { Hono } from "hono";
import { parseTokenId } from "../lib/validation.js";
import { getLegendaryCanvasInfo, getLegendaryCanvases } from "../services/legendary-canvas-data.js";

const legendaryCanvas = new Hono();

legendaryCanvas.get("/", async (c) => {
    const { limit, offset } = parsePagination(c);
    return c.json(await getLegendaryCanvases(limit, offset));
});

legendaryCanvas.get("/token/:id", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    return c.json(await getLegendaryCanvasInfo(result.tokenId));
});

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50), 1), 100);
    const offset = Math.max(Number(c.req.query("offset") ?? 0), 0);
    return { limit, offset };
}

export { legendaryCanvas };

import { Hono } from "hono";
import { parseTokenId } from "../lib/validation.js";
import { imageDataToPixelString } from "../lib/pixels.js";
import { renderSvg } from "../lib/svg.js";
import { svgToPng } from "../lib/png.js";
import {
    getZombieAttributes,
    getZombieBitmap,
    getZombieConversions,
    getZombieConversionsForToken,
    getZombieConversionsForWallet,
    getZombieInfo,
    getZombieStatus,
} from "../services/zombie-data.js";

const zombies = new Hono();

zombies.get("/status", async (c) => {
    return c.json(await getZombieStatus());
});

zombies.get("/conversions", async (c) => {
    const { limit, offset } = parsePagination(c);
    return c.json(await getZombieConversions(limit, offset));
});

zombies.get("/wallet/:address", async (c) => {
    const { limit, offset } = parsePagination(c);
    return c.json(await getZombieConversionsForWallet(c.req.param("address"), limit, offset));
});

zombies.get("/token/:id", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    return c.json({
        info: await getZombieInfo(result.tokenId),
        conversions: await getZombieConversionsForToken(result.tokenId),
    });
});

zombies.get("/token/:id/attributes", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    return c.json({ attributes: await getZombieAttributes(result.tokenId) });
});

zombies.get("/token/:id/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const pixels = imageDataToPixelString(await getZombieBitmap(result.tokenId));
    return c.text(pixels);
});

zombies.get("/token/:id/image.svg", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const svg = renderSvg(await getZombieBitmap(result.tokenId));
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

zombies.get("/token/:id/image.png", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const svg = renderSvg(await getZombieBitmap(result.tokenId));
    const png = svgToPng(svg);
    return new Response(png, { status: 200, headers: { "Content-Type": "image/png" } });
});

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50), 1), 100);
    const offset = Math.max(Number(c.req.query("offset") ?? 0), 0);
    return { limit, offset };
}

export { zombies };

import { Hono } from "hono";
import { PIXEL_MARKET_ENABLED } from "../config.js";
import {
    getPixelActivity,
    getPixelBalance,
    getPixelHolders,
    getPixelSupply,
    getTokenPixelsBatch,
} from "../services/pixel-market-data.js";
import { getTokensByHolder } from "../services/ponder-data.js";

const pixels = new Hono();

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50), 1), 100);
    const offset = Math.max(Number(c.req.query("offset") ?? 0), 0);
    return { limit, offset };
}

pixels.use("*", async (c, next) => {
    if (!PIXEL_MARKET_ENABLED) return c.json({ error: "Pixel Market features are not enabled" }, 404);
    await next();
});

// Wallet balance plus the pixels sitting on the wallet's Normies.
pixels.get("/balance/:address", async (c) => {
    const address = c.req.param("address");
    if (!ADDRESS_RE.test(address)) return c.json({ error: "Invalid Ethereum address" }, 400);

    const [balance, tokenIds] = await Promise.all([getPixelBalance(address), getTokensByHolder(address)]);
    const tokens = tokenIds.length > 0 ? await getTokenPixelsBatch(tokenIds) : {};
    let attached = 0n;
    let locked = 0n;
    const perToken = tokenIds.map((tokenId) => {
        const t = tokens[tokenId];
        const a = BigInt(t?.attached ?? "0");
        const l = BigInt(t?.locked ?? "0");
        attached += a;
        locked += l;
        return {
            tokenId,
            attached: a.toString(),
            locked: l.toString(),
            free: (a > l ? a - l : 0n).toString(),
            gridSize: t?.gridSize ?? 40,
            baseCleared: t?.baseCleared ?? false,
            customized: t?.customized ?? false,
        };
    });

    return c.json({
        address: address.toLowerCase(),
        balance: balance.balance,
        attached: attached.toString(),
        locked: locked.toString(),
        free: (attached > locked ? attached - locked : 0n).toString(),
        tokens: perToken,
        updatedBlock: balance.updatedBlock,
    });
});

pixels.get("/holders", async (c) => {
    const { limit, offset } = parsePagination(c);
    return c.json(await getPixelHolders(limit, offset));
});

pixels.get("/activity/:address", async (c) => {
    const address = c.req.param("address");
    if (!ADDRESS_RE.test(address)) return c.json({ error: "Invalid Ethereum address" }, 400);
    const { limit, offset } = parsePagination(c);
    return c.json(await getPixelActivity(address, limit, offset));
});

pixels.get("/supply", async (c) => {
    return c.json(await getPixelSupply());
});

export { pixels };

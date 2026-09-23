import { Hono } from "hono";
import { PIXEL_MARKET_ENABLED } from "../config.js";
import { getCanvasStatus } from "../services/canvas-data.js";
import {
    getMarketCandles,
    getMarketDepth,
    getMarketFills,
    getMarketFillsForAddress,
    getMarketListing,
    getMarketListings,
    getMarketStats,
    type ListingSort,
    type ListingStatus,
} from "../services/pixel-market-data.js";

const market = new Hono();

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const SORTS: ListingSort[] = ["price-asc", "price-desc", "amount-desc", "newest"];
const STATUSES: Array<ListingStatus | "all"> = ["active", "filled", "cancelled", "all"];

function parsePagination(c: { req: { query: (key: string) => string | undefined } }) {
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 50), 1), 100);
    const offset = Math.max(Number(c.req.query("offset") ?? 0), 0);
    return { limit, offset };
}

market.use("*", async (c, next) => {
    if (!PIXEL_MARKET_ENABLED) return c.json({ error: "Pixel Market features are not enabled" }, 404);
    await next();
});

market.get("/status", async (c) => {
    const status = await getCanvasStatus();
    return c.json(status.pixelMarket ?? { error: "Pixel Market status unavailable" });
});

market.get("/listings", async (c) => {
    const { limit, offset } = parsePagination(c);
    const statusRaw = c.req.query("status") ?? "active";
    if (!STATUSES.includes(statusRaw as ListingStatus | "all")) {
        return c.json({ error: "status must be active, filled, cancelled or all" }, 400);
    }
    const sortRaw = c.req.query("sort") ?? "price-asc";
    if (!SORTS.includes(sortRaw as ListingSort)) {
        return c.json({ error: `sort must be one of ${SORTS.join(", ")}` }, 400);
    }
    const seller = c.req.query("seller");
    if (seller !== undefined && !ADDRESS_RE.test(seller)) return c.json({ error: "Invalid seller" }, 400);
    const partialRaw = c.req.query("partial");
    const partial = partialRaw === "true" ? true : partialRaw === "false" ? false : undefined;

    return c.json(await getMarketListings({
        status: statusRaw as ListingStatus | "all",
        sort: sortRaw as ListingSort,
        seller,
        partial,
        expired: c.req.query("expired") === "true",
        limit,
        offset,
    }));
});

market.get("/listings/:id", async (c) => {
    const id = c.req.param("id");
    if (!/^\d+$/.test(id)) return c.json({ error: "Invalid listing id" }, 400);
    return c.json(await getMarketListing(id));
});

market.get("/depth", async (c) => {
    return c.json(await getMarketDepth());
});

market.get("/fills", async (c) => {
    const { limit, offset } = parsePagination(c);
    const afterTimestamp = c.req.query("after_timestamp") ?? c.req.query("since_timestamp");
    if (afterTimestamp !== undefined && !/^\d+$/.test(afterTimestamp)) {
        return c.json({ error: "`after_timestamp` must be a non-negative unix timestamp string" }, 400);
    }
    const sortRaw = c.req.query("sort");
    const sort = sortRaw === "asc" || sortRaw === "desc" ? sortRaw : afterTimestamp ? "asc" : "desc";
    return c.json(await getMarketFills({ limit, offset, afterTimestamp, sort }));
});

market.get("/fills/address/:address", async (c) => {
    const address = c.req.param("address");
    if (!ADDRESS_RE.test(address)) return c.json({ error: "Invalid Ethereum address" }, 400);
    const { limit, offset } = parsePagination(c);
    return c.json(await getMarketFillsForAddress(address, limit, offset));
});

market.get("/stats", async (c) => {
    return c.json(await getMarketStats());
});

market.get("/candles", async (c) => {
    const interval = c.req.query("interval") ?? "1h";
    if (interval !== "1h" && interval !== "4h" && interval !== "1d") {
        return c.json({ error: "interval must be 1h, 4h or 1d" }, 400);
    }
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 168), 1), 1000);
    return c.json(await getMarketCandles(interval, limit));
});

export { market };

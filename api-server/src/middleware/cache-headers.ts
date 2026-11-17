import type { MiddlewareHandler } from "hono";
import {
    CANVAS_INFO_CACHE_TTL_MS,
    CANVAS_STATUS_CACHE_TTL_MS,
    MARKET_CACHE_TTL_MS,
    ZOMBIE_STATUS_CACHE_TTL_MS,
} from "../config.js";

const canvasInfoMaxAge = Math.floor(CANVAS_INFO_CACHE_TTL_MS / 1000);
const canvasStatusMaxAge = Math.floor(CANVAS_STATUS_CACHE_TTL_MS / 1000);
const zombieStatusMaxAge = Math.floor(ZOMBIE_STATUS_CACHE_TTL_MS / 1000);
const marketMaxAge = Math.max(1, Math.floor(MARKET_CACHE_TTL_MS / 1000));

export const cacheHeaders: MiddlewareHandler = async (c, next) => {
    await next();
    // An error is about this moment, not the resource: a cached 500 or 502 would keep failing for
    // every visitor long after the indexer recovered. A "not found" may be cached briefly.
    const status = c.res.status;
    if (status === 404 || status === 410) {
        c.header("Cache-Control", "public, max-age=30, s-maxage=30");
        return;
    }
    if (status >= 400) {
        c.header("Cache-Control", "no-store");
        return;
    }
    const path = c.req.path;
    if (path.startsWith("/canvas/status")) {
        c.header("Cache-Control", `public, max-age=${canvasStatusMaxAge}, s-maxage=${canvasStatusMaxAge}`);
    } else if (path === "/revshare/epochs" || /^\/revshare\/epochs\/\d+$/.test(path)) {
        // Epochs carry OpenSea and price lookups: let the CDN absorb the site's polling and refresh in the background.
        c.header("Cache-Control", "public, max-age=30, s-maxage=60, stale-while-revalidate=3600");
    } else if (path.startsWith("/market/") || path.startsWith("/arena/") || path.startsWith("/revshare/") || path.startsWith("/pixels/") || path.startsWith("/canvas/sinks") || path.startsWith("/canvas/token/")) {
        // Order book, balances and Arena state: near-realtime, short shared cache
        c.header("Cache-Control", `public, max-age=${marketMaxAge}, s-maxage=${marketMaxAge}`);
    } else if (path.startsWith("/zombies/status")) {
        c.header("Cache-Control", `public, max-age=${zombieStatusMaxAge}, s-maxage=${zombieStatusMaxAge}`);
    } else if (path.startsWith("/rarity/admin/") || path.startsWith("/rarity/listings/stream")) {
        c.header("Cache-Control", "no-store");
    } else if (path.startsWith("/rarity/")) {
        c.header("Cache-Control", "public, max-age=15, s-maxage=30, stale-while-revalidate=120");
    } else if (path.includes("/canvas/info")) {
        c.header("Cache-Control", `public, max-age=${canvasInfoMaxAge}, s-maxage=${canvasInfoMaxAge}`);
    } else if (path.includes("/owner") || path.startsWith("/holders/") || path.startsWith("/delegations/")) {
        // Near-realtime mutable data (ownership, action points, level, delegate, paused state)
        c.header("Cache-Control", "public, max-age=10, s-maxage=10");
    } else if (path.includes("/original/") || path.includes("/traits")) {
        // Immutable original data — long cache
        c.header("Cache-Control", "public, max-age=300, s-maxage=3600");
    } else if (path === "/normie/images" || /^\/normie\/\d+\/image\.(svg|png)$/.test(path)) {
        // Current art: fresh for 5 minutes, then the edge answers with what it has while it redraws
        // in the background. A grid never waits on a redraw of 200 SVGs (about a second), and an
        // edit shows after at most one refresh.
        c.header("Cache-Control", "public, max-age=60, s-maxage=300, stale-while-revalidate=86400");
    } else if (/^\/history\/normie\/\d+\/version\/\d+\//.test(path)) {
        // A past version never changes once indexed, and the site's history strips load one image
        // per version. A long edge TTL keeps those strips off the per-IP rate limit. Kept to a day
        // (not immutable) so a version caught in a reorg near the tip still corrects itself.
        c.header("Cache-Control", "public, max-age=3600, s-maxage=86400, stale-while-revalidate=604800");
    } else if (path.startsWith("/history/")) {
        // Historical/indexed data — append-only, moderate cache
        c.header("Cache-Control", "public, max-age=60, s-maxage=300");
    } else {
        // Composited endpoints, canvas/pixels, canvas/diff — moderate cache
        c.header("Cache-Control", "public, max-age=60, s-maxage=300");
    }
};

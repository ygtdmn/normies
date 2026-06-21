import type { MiddlewareHandler } from "hono";
import { CANVAS_INFO_CACHE_TTL_MS, CANVAS_STATUS_CACHE_TTL_MS, ZOMBIE_STATUS_CACHE_TTL_MS } from "../config.js";

const canvasInfoMaxAge = Math.floor(CANVAS_INFO_CACHE_TTL_MS / 1000);
const canvasStatusMaxAge = Math.floor(CANVAS_STATUS_CACHE_TTL_MS / 1000);
const zombieStatusMaxAge = Math.floor(ZOMBIE_STATUS_CACHE_TTL_MS / 1000);

export const cacheHeaders: MiddlewareHandler = async (c, next) => {
    await next();
    const path = c.req.path;
    if (path.startsWith("/canvas/status")) {
        c.header("Cache-Control", `public, max-age=${canvasStatusMaxAge}, s-maxage=${canvasStatusMaxAge}`);
    } else if (path.startsWith("/zombies/status")) {
        c.header("Cache-Control", `public, max-age=${zombieStatusMaxAge}, s-maxage=${zombieStatusMaxAge}`);
    } else if (path.startsWith("/rarity/admin/") || path.startsWith("/rarity/listings/stream")) {
        c.header("Cache-Control", "no-store");
    } else if (path.startsWith("/rarity/")) {
        c.header("Cache-Control", "public, max-age=15, s-maxage=30, stale-while-revalidate=120");
    } else if (path.includes("/canvas/info")) {
        c.header("Cache-Control", `public, max-age=${canvasInfoMaxAge}, s-maxage=${canvasInfoMaxAge}`);
    } else if (path.includes("/owner") || path.startsWith("/holders/")) {
        // Near-realtime mutable data (ownership, action points, level, delegate, paused state)
        c.header("Cache-Control", "public, max-age=10, s-maxage=10");
    } else if (path.includes("/original/") || path.includes("/traits")) {
        // Immutable original data — long cache
        c.header("Cache-Control", "public, max-age=300, s-maxage=3600");
    } else if (path.startsWith("/history/")) {
        // Historical/indexed data — append-only, moderate cache
        c.header("Cache-Control", "public, max-age=60, s-maxage=300");
    } else {
        // Composited endpoints, canvas/pixels, canvas/diff — moderate cache
        c.header("Cache-Control", "public, max-age=60, s-maxage=300");
    }
};

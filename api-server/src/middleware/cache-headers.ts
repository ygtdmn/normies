import type { MiddlewareHandler } from "hono";

export const cacheHeaders: MiddlewareHandler = async (c, next) => {
    await next();
    const path = c.req.path;
    if (path.includes("/canvas/info") || path.startsWith("/canvas/status") || path.includes("/owner") || path.startsWith("/holders/")) {
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

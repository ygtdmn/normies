import type { MiddlewareHandler } from "hono";

export const cacheHeaders: MiddlewareHandler = async (c, next) => {
    await next();
    if (c.res.status >= 200 && c.res.status < 300) {
        const path = c.req.path;
        if (path.includes("/canvas/info") || path.startsWith("/canvas/status")) {
            // Near-realtime mutable data (action points, level, delegate, paused state)
            c.header("Cache-Control", "public, max-age=10, s-maxage=10");
        } else if (path.includes("/original/") || path.includes("/traits")) {
            // Immutable original data — long cache
            c.header("Cache-Control", "public, max-age=300, s-maxage=3600");
        } else {
            // Composited endpoints, canvas/pixels, canvas/diff — moderate cache
            c.header("Cache-Control", "public, max-age=60, s-maxage=300");
        }
    }
};

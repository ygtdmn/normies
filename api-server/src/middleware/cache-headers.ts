import type { MiddlewareHandler } from "hono";

export const cacheHeaders: MiddlewareHandler = async (c, next) => {
    await next();
    if (c.res.status >= 200 && c.res.status < 300) {
        c.header("Cache-Control", "public, max-age=300, s-maxage=3600");
    }
};

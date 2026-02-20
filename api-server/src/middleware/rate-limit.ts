import type { MiddlewareHandler } from "hono";
import { RATE_LIMIT_WINDOW_MS, RATE_LIMIT_MAX_REQUESTS } from "../config.js";

const clients = new Map<string, number[]>();

// Clean up stale entries every 5 minutes
setInterval(() => {
    const now = Date.now();
    for (const [key, timestamps] of clients) {
        const active = timestamps.filter((t) => now - t < RATE_LIMIT_WINDOW_MS);
        if (active.length === 0) {
            clients.delete(key);
        } else {
            clients.set(key, active);
        }
    }
}, 5 * 60_000).unref();

export const rateLimiter: MiddlewareHandler = async (c, next) => {
    const ip =
        c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ??
        c.req.header("x-real-ip") ??
        "unknown";

    const now = Date.now();
    let timestamps = clients.get(ip);

    if (!timestamps) {
        timestamps = [];
        clients.set(ip, timestamps);
    }

    // Remove timestamps outside the window
    const cutoff = now - RATE_LIMIT_WINDOW_MS;
    while (timestamps.length > 0 && timestamps[0] < cutoff) {
        timestamps.shift();
    }

    if (timestamps.length >= RATE_LIMIT_MAX_REQUESTS) {
        c.header("Retry-After", String(Math.ceil(RATE_LIMIT_WINDOW_MS / 1000)));
        c.header("X-RateLimit-Limit", String(RATE_LIMIT_MAX_REQUESTS));
        c.header("X-RateLimit-Remaining", "0");
        return c.json({ error: "Rate limit exceeded. Try again later." }, 429);
    }

    timestamps.push(now);

    c.header("X-RateLimit-Limit", String(RATE_LIMIT_MAX_REQUESTS));
    c.header("X-RateLimit-Remaining", String(RATE_LIMIT_MAX_REQUESTS - timestamps.length));

    await next();
};

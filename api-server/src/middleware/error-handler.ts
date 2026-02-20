import type { ErrorHandler } from "hono";

export const errorHandler: ErrorHandler = (err, c) => {
    console.error(`[ERROR] ${c.req.method} ${c.req.path}:`, err);

    const message = err instanceof Error ? err.message : "Internal server error";

    if (message.includes("TokenDataNotSet") || message.includes("revert")) {
        return c.json({ error: "Token not found or data not set" }, 404);
    }

    return c.json({ error: "Internal server error" }, 500);
};

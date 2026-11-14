import type { Server } from "node:http";
import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { HOST, PORT, PONDER_API_SECRET, PONDER_API_URL } from "./config.js";
import { rateLimiter } from "./middleware/rate-limit.js";
import { cacheHeaders } from "./middleware/cache-headers.js";
import { errorHandler } from "./middleware/error-handler.js";
import { normie } from "./routes/normie.js";
import { canvas } from "./routes/canvas.js";
import { history } from "./routes/history.js";
import { holders } from "./routes/holders.js";
import { delegations } from "./routes/delegations.js";
import { docs } from "./routes/docs.js";
import { llms } from "./routes/llms.js";
import { agents } from "./routes/agents.js";
import { zombies } from "./routes/zombies.js";
import { legendaryCanvas } from "./routes/legendary-canvas.js";
import { rarity } from "./routes/rarity.js";
import { pixels } from "./routes/pixels.js";
import { market } from "./routes/market.js";
import { revshare } from "./routes/revshare.js";
import { arena } from "./routes/arena.js";

import { closeListingStreams } from "./lib/listing-stream.js";

const app = new Hono();

app.use("*", async (c, next) => {
    await next();
    if (c.res.status >= 400) c.res.headers.set("Cache-Control", "no-store");
});
app.use("*", logger());
app.use("*", cors());
app.get("/health", (c) => {
    c.header("Cache-Control", "no-store");
    return c.json({ status: "ok" });
});

app.get("/ready", async (c) => {
    c.header("Cache-Control", "no-store");
    const release = process.env.NORMIES_API_RELEASE ?? "development";
    try {
        const response = await fetch(PONDER_API_URL + "/ready", {
            headers: PONDER_API_SECRET ? { "X-Ponder-Secret": PONDER_API_SECRET } : {},
            signal: AbortSignal.timeout(2500),
            redirect: "error",
        });
        await response.body?.cancel();
        if (response.status === 200) return c.json({ status: "ready", release });
    } catch {
        // Do not disclose upstream URLs or credentials.
    }
    return c.json({ status: "not ready", release }, 503);
});

app.use("*", rateLimiter);
app.use("/normie/*", cacheHeaders);
app.use("/canvas/*", cacheHeaders);
app.use("/pixels/*", cacheHeaders);
app.use("/market/*", cacheHeaders);
app.use("/revshare/*", cacheHeaders);
app.use("/arena/*", cacheHeaders);
app.use("/history/*", cacheHeaders);
app.use("/holders/*", cacheHeaders);
app.use("/delegations/*", cacheHeaders);
app.use("/zombies/*", cacheHeaders);
app.use("/legendary-canvas/*", cacheHeaders);
app.use("/rarity/*", cacheHeaders);

app.onError(errorHandler);

app.route("/", docs);
app.route("/", llms);
app.route("/normie", normie);
app.route("/canvas", canvas);
app.route("/history", history);
app.route("/holders", holders);
app.route("/delegations", delegations);
app.route("/agents", agents);
app.route("/zombies", zombies);
app.route("/legendary-canvas", legendaryCanvas);
app.route("/rarity", rarity);
app.route("/pixels", pixels);
app.route("/market", market);
app.route("/revshare", revshare);
app.route("/arena", arena);

const server = serve({ fetch: app.fetch, hostname: HOST, port: PORT }, ({ address, port }) => {
    console.log("Normies API listening on", address, port);
});

let stopping = false;
function shutdown() {
    if (stopping) return;
    stopping = true;
    const deadline = setTimeout(() => (server as Server).closeAllConnections(), 60_000);
    server.close(() => clearTimeout(deadline));
    closeListingStreams();
}

process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);

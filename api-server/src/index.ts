import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { AGENTS_RECONCILE_INTERVAL_MS, PONDER_ENABLED, PORT } from "./config.js";
import { rateLimiter } from "./middleware/rate-limit.js";
import { cacheHeaders } from "./middleware/cache-headers.js";
import { errorHandler } from "./middleware/error-handler.js";
import { normie } from "./routes/normie.js";
import { canvas } from "./routes/canvas.js";
import { history } from "./routes/history.js";
import { holders } from "./routes/holders.js";
import { docs } from "./routes/docs.js";
import { llms } from "./routes/llms.js";
import { agents } from "./routes/agents.js";
import { reconcileAll } from "./services/agents-reconcile.js";

const app = new Hono();

app.use("*", logger());
app.use("*", cors());
app.use("*", rateLimiter);
app.use("/normie/*", cacheHeaders);
app.use("/canvas/*", cacheHeaders);
app.use("/history/*", cacheHeaders);
app.use("/holders/*", cacheHeaders);

app.onError(errorHandler);

app.route("/", docs);
app.route("/", llms);
app.route("/normie", normie);
app.route("/canvas", canvas);
app.route("/history", history);
app.route("/holders", holders);
app.route("/agents", agents);

app.get("/health", (c) => c.json({ status: "ok" }));

console.log(`Normies API server starting on http://localhost:${PORT}`);
serve({ fetch: app.fetch, port: PORT });

// Periodic backfill: sweep Ponder's agent_binding table and promote any
// agentsPrisma rows that on-chain registrations have outpaced. Catches users
// who registered but closed the lab page before /register-complete ran. Only
// runs when the indexer is reachable and the interval is set above zero.
if (PONDER_ENABLED && AGENTS_RECONCILE_INTERVAL_MS > 0) {
    const runSweep = async () => {
        try {
            const summary = await reconcileAll();
            if (summary.promoted > 0 || summary.errors > 0) {
                console.log(
                    `[agents-reconcile] scanned=${summary.scanned} promoted=${summary.promoted} already=${summary.alreadyRegistered} errors=${summary.errors}`,
                );
            }
        } catch (err) {
            console.error("[agents-reconcile] sweep failed:", err);
        }
    };
    // Kick off the first sweep after a short delay so server startup isn't
    // gated on indexer/DB latency, then run on the configured cadence.
    setTimeout(runSweep, 10_000);
    setInterval(runSweep, AGENTS_RECONCILE_INTERVAL_MS);
}

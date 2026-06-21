import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { PORT } from "./config.js";
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
import { zombies } from "./routes/zombies.js";
import { legendaryCanvas } from "./routes/legendary-canvas.js";
import { rarity } from "./routes/rarity.js";

const app = new Hono();

app.use("*", logger());
app.use("*", cors());
app.use("*", rateLimiter);
app.use("/normie/*", cacheHeaders);
app.use("/canvas/*", cacheHeaders);
app.use("/history/*", cacheHeaders);
app.use("/holders/*", cacheHeaders);
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
app.route("/agents", agents);
app.route("/zombies", zombies);
app.route("/legendary-canvas", legendaryCanvas);
app.route("/rarity", rarity);

app.get("/health", (c) => c.json({ status: "ok" }));

console.log(`Normies API server starting on http://localhost:${PORT}`);
serve({ fetch: app.fetch, port: PORT });

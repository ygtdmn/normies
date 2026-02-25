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
import { docs } from "./routes/docs.js";
import { llms } from "./routes/llms.js";

const app = new Hono();

app.use("*", logger());
app.use("*", cors());
app.use("*", rateLimiter);
app.use("/normie/*", cacheHeaders);
app.use("/canvas/*", cacheHeaders);

app.onError(errorHandler);

app.route("/", docs);
app.route("/", llms);
app.route("/normie", normie);
app.route("/canvas", canvas);

app.get("/health", (c) => c.json({ status: "ok" }));

console.log(`Normies API server starting on http://localhost:${PORT}`);
serve({ fetch: app.fetch, port: PORT });

import { Hono } from "hono";
import { getCanvasStatus } from "../services/canvas-data.js";
import { CANVAS_ENABLED } from "../config.js";

const canvas = new Hono();

canvas.get("/status", async (c) => {
    if (!CANVAS_ENABLED) {
        return c.json({ error: "Canvas features are not enabled" }, 404);
    }
    const status = await getCanvasStatus();
    return c.json(status);
});

export { canvas };

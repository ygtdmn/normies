import { Hono } from "hono";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const docs = new Hono();
const __dirname = dirname(fileURLToPath(import.meta.url));

const html = readFileSync(resolve(__dirname, "../content/docs.html"), "utf-8");

docs.get("/", (c) => {
    return c.html(html);
});

export { docs };

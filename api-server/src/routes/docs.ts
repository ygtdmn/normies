import { Hono } from "hono";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const docs = new Hono();
const __dirname = dirname(fileURLToPath(import.meta.url));

const html = readFileSync(resolve(__dirname, "../content/docs.html"), "utf-8");
const favicon = readFileSync(resolve(__dirname, "../content/favicon.png"));

docs.get("/", (c) => {
    return c.html(html);
});

docs.get("/favicon.png", (c) => {
    c.header("Content-Type", "image/png");
    c.header("Cache-Control", "public, max-age=86400");
    return c.body(favicon.buffer.slice(favicon.byteOffset, favicon.byteOffset + favicon.byteLength) as ArrayBuffer);
});

docs.get("/favicon.ico", (c) => {
    c.header("Content-Type", "image/png");
    c.header("Cache-Control", "public, max-age=86400");
    return c.body(favicon.buffer.slice(favicon.byteOffset, favicon.byteOffset + favicon.byteLength) as ArrayBuffer);
});

export { docs };

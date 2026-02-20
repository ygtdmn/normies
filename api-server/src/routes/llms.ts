import { Hono } from "hono";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const llms = new Hono();
const __dirname = dirname(fileURLToPath(import.meta.url));

const content = readFileSync(resolve(__dirname, "../content/llms.txt"), "utf-8");

llms.get("/llms.txt", (c) => {
    return c.text(content);
});

export { llms };

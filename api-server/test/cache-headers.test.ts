import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { cacheHeaders } from "../src/middleware/cache-headers.js";

const app = new Hono();
app.use("/history/*", cacheHeaders);
app.get("/history/*", (c) => c.text("ok"));

const cacheControl = async (path: string) => (await app.request(path)).headers.get("Cache-Control");

describe("cache headers for history", () => {
    it("caches a past version at the edge for a day", async () => {
        for (const leaf of ["image.svg", "image.png", "pixels"]) {
            expect(await cacheControl(`/history/normie/1/version/3/${leaf}`)).toBe(
                "public, max-age=3600, s-maxage=86400, stale-while-revalidate=604800",
            );
        }
    });

    it("keeps the version list and other history on the short tier", async () => {
        for (const path of ["/history/normie/1/versions", "/history/burns", "/history/stats"]) {
            expect(await cacheControl(path)).toBe("public, max-age=60, s-maxage=300");
        }
    });
});

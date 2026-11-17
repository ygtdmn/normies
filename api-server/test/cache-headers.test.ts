import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { cacheHeaders } from "../src/middleware/cache-headers.js";

const app = new Hono();
app.use("/history/*", cacheHeaders);
app.get("/history/fail/:status", (c) => c.text("no", Number(c.req.param("status")) as 404));
app.get("/history/throw", () => {
    throw new Error("Ponder API 503");
});
app.get("/history/*", (c) => c.text("ok"));
app.onError((_err, c) => c.json({ error: "Bad gateway" }, 502));

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

describe("cache headers for errors", () => {
    it("never lets a cache keep a server error or a refusal", async () => {
        for (const status of [400, 429, 500, 502, 503]) {
            expect(await cacheControl(`/history/fail/${status}`)).toBe("no-store");
        }
        // A thrown error reaches the client through onError, under the same rule.
        expect(await cacheControl("/history/throw")).toBe("no-store");
    });

    it("caches not found only briefly", async () => {
        for (const status of [404, 410]) {
            expect(await cacheControl(`/history/fail/${status}`)).toBe("public, max-age=30, s-maxage=30");
        }
    });
});

describe("cache headers for current art", () => {
    const art = new Hono();
    art.use("/normie/*", cacheHeaders);
    art.get("/normie/*", (c) => c.text("ok"));
    const of = async (path: string) => (await art.request(path)).headers.get("Cache-Control");

    it("lets the edge serve stale art while it redraws", async () => {
        for (const path of ["/normie/images?ids=1,2", "/normie/7/image.svg", "/normie/7/image.png"]) {
            expect(await of(path)).toBe("public, max-age=60, s-maxage=300, stale-while-revalidate=86400");
        }
    });

    it("leaves other Normie routes on the default", async () => {
        for (const path of ["/normie/7/metadata", "/normie/7/pixels"]) {
            expect(await of(path)).toBe("public, max-age=60, s-maxage=300");
        }
    });
});

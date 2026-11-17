import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { parseInternalKeys } from "../src/config.js";
import { TIERS, TokenBuckets, clientAddress, costOf, ipv6Prefix64, tierOf } from "../src/lib/rate-policy.js";
import { createRateLimiter, routeShape, type RateLimiterOptions } from "../src/middleware/rate-limit.js";

const headers = (h: Record<string, string>) => (name: string) => h[name.toLowerCase()];
const noQuery = () => undefined;

describe("who is calling", () => {
    it("prefers X-Real-IP and groups IPv6 by /64", () => {
        expect(clientAddress(headers({ "x-real-ip": "203.0.113.7", "x-forwarded-for": "198.51.100.1" }))).toBe("203.0.113.7");
        expect(clientAddress(headers({ "x-forwarded-for": "198.51.100.1, 10.0.0.1" }))).toBe("198.51.100.1");
        expect(clientAddress(headers({}))).toBe("unknown");
        expect(ipv6Prefix64("2a02:8071:7cd1:1234:abcd:ef01:2345:6789")).toBe("2a02:8071:7cd1:1234::/64");
        expect(ipv6Prefix64("2a02:8071:7cd1:1234::1")).toBe("2a02:8071:7cd1:1234::/64");
        expect(ipv6Prefix64("2001:db8::1")).toBe("2001:db8:0:0::/64");
        expect(ipv6Prefix64("::ffff:192.0.2.9")).toBe("192.0.2.9");
    });

    it("puts normies.art pages in the website tier, bulk crawlers in the crawler tier", () => {
        expect(tierOf(headers({ origin: "https://www.normies.art" }))).toBe("website");
        expect(tierOf(headers({ referer: "https://arena.normies.art/world" }))).toBe("website");
        expect(tierOf(headers({ origin: "https://evil-normies.art" }))).toBe("public");
        expect(tierOf(headers({ referer: "https://normies.art.example.com/" }))).toBe("public");
        expect(tierOf(headers({ "user-agent": "Mozilla/5.0 (compatible; GPTBot/1.4)" }))).toBe("crawler");
        expect(tierOf(headers({ "user-agent": "SealKeeperBot/1.0 (+https://sealkeeper.run)" }))).toBe("crawler");
        // Link previews fetch for many people from shared addresses: not throttled as crawlers.
        expect(tierOf(headers({ "user-agent": "Mozilla/5.0 (compatible; Discordbot/2.0)" }))).toBe("public");
        expect(tierOf(headers({ "user-agent": "node" }))).toBe("public");
    });

    it("reads per-service keys and ignores short or malformed ones", () => {
        const keys = parseInternalKeys("site:aaaaaaaaaaaaaaaa1, arena:bbbbbbbbbbbbbbbb2,bad:short,:nokey", "shared-secret-value");
        expect([...keys.values()].sort()).toEqual(["arena", "shared", "site"]);
        expect(keys.get("aaaaaaaaaaaaaaaa1")).toBe("site");
    });
});

describe("what a request costs", () => {
    it("weighs batches and heavy routes", () => {
        const ids = (n: number) => (name: string) => (name === "ids" ? Array.from({ length: n }, (_, i) => i).join(",") : undefined);
        expect(costOf("/normie/1/image.svg", noQuery)).toBe(1);
        expect(costOf("/normie/images", ids(200))).toBe(5);
        expect(costOf("/normie/images", ids(10))).toBe(2);
        expect(costOf("/normie/all/original/data", noQuery)).toBe(10);
        expect(costOf("/agents/persona-preview/5", noQuery)).toBe(5);
        expect(costOf("/history/normie/1/versions", (n) => (n === "pixels" ? "1" : undefined))).toBe(2);
        expect(costOf("/history/normie/1/versions", noQuery)).toBe(1);
    });
});

describe("token buckets", () => {
    it("passes a burst, holds a little, then says exactly how long to wait", () => {
        let t = 0;
        const buckets = new TokenBuckets(() => t);
        const policy = { burst: 3, perSecond: 1 };
        for (let i = 0; i < 3; i++) expect(buckets.take("a", policy, 1).action).toBe("allow");
        expect(buckets.take("a", policy, 1)).toMatchObject({ action: "hold", waitMs: 1000 });
        expect(buckets.take("a", policy, 1)).toMatchObject({ action: "hold", waitMs: 2000 });
        // The queue ahead now needs 3 s: too long to hold, so a 429 with the real wait.
        expect(buckets.take("a", policy, 1)).toMatchObject({ action: "reject", retryAfterMs: 3000 });
        t = 5_000;
        expect(buckets.take("a", policy, 1).action).toBe("allow");
    });

    it("caps how many requests one caller can have waiting", () => {
        const buckets = new TokenBuckets(() => 0);
        const policy = { burst: 1, perSecond: 1000 };
        buckets.take("a", policy, 1);
        for (let i = 0; i < 4; i++) expect(buckets.take("a", policy, 1).action).toBe("hold");
        expect(buckets.take("a", policy, 1).action).toBe("reject");
        buckets.release("a");
        expect(buckets.take("a", policy, 1).action).toBe("hold");
    });

    it("forgets buckets that have refilled", () => {
        let t = 0;
        const buckets = new TokenBuckets(() => t);
        buckets.take("public:1", TIERS.public, 50);
        buckets.take("public:2", TIERS.public, 1);
        t = 60_000;
        buckets.prune(() => TIERS.public);
        expect(buckets.size).toBe(0);
    });
});

const KEY = "site-key-0123456789";

function harness(mode: RateLimiterOptions["mode"], extra: Partial<RateLimiterOptions> = {}) {
    let t = 1_000_000;
    const waits: number[] = [];
    const limiter = createRateLimiter({
        mode,
        keys: new Map([[KEY, "site"]]),
        legacyMax: 3,
        legacyWindowMs: 60_000,
        now: () => t,
        sleep: async (ms) => {
            waits.push(ms);
            t += ms;
        },
        ...extra,
    });
    const app = new Hono();
    app.use("*", limiter.middleware);
    app.get("/cached", (c) => c.json({ ok: true }, 200, { "Cache-Control": "public, max-age=60, s-maxage=300" }));
    app.get("/history/burns/:id", (c) => c.json({ error: "Not found" }, 404));
    app.get("*", (c) => c.json({ ok: true }));
    const hit = (path = "/x", h: Record<string, string> = {}) =>
        app.request(path, { headers: { "x-real-ip": "198.51.100.5", ...h } });
    return { limiter, hit, waits, advance: (ms: number) => (t += ms) };
}

describe("enforce mode", () => {
    it("lets a public burst through, holds the overflow briefly, then 429s with the real wait", async () => {
        const { hit, waits } = harness("enforce");
        for (let i = 0; i < TIERS.public.burst; i++) expect((await hit()).status).toBe(200);
        // Short by one token at 1/s: waits a second, then succeeds.
        expect((await hit()).status).toBe(200);
        expect(waits).toEqual([1000]);
        // The clock moved through that wait; the next ones queue up behind it.
        expect((await hit()).status).toBe(200);
        expect((await hit()).status).toBe(200);
        expect(waits).toEqual([1000, 1000, 1000]);
    });

    it("rejects past the hold window and says when to come back", async () => {
        const { hit, waits } = harness("enforce", { sleep: async (ms) => void waits.push(ms) });
        for (let i = 0; i < TIERS.public.burst; i++) await hit();
        // The clock never moves, so the queue deepens: 1 s, 2 s, then 3 s is too long.
        expect((await hit()).status).toBe(200);
        expect((await hit()).status).toBe(200);
        const res = await hit();
        expect(res.status).toBe(429);
        expect(res.headers.get("Retry-After")).toBe("3");
        expect(res.headers.get("Cache-Control")).toBe("no-store");
        expect(await res.json()).toMatchObject({ retryAfter: 3 });
    });

    it("gives normies.art pages a bigger bucket and internal keys their own", async () => {
        const { hit, limiter } = harness("enforce", { sleep: async () => {} });
        for (let i = 0; i < 200; i++) expect((await hit("/x", { origin: "https://www.normies.art" })).status).toBe(200);
        for (let i = 0; i < 300; i++) expect((await hit("/x", { "x-internal-secret": KEY })).status).toBe(200);
        const snap = limiter.snapshot();
        expect(snap.tiers.website.requests).toBe(200);
        expect(snap.internalKeys.site.requests).toBe(300);
        expect(snap.tiers.website.rejected + snap.tiers.internal.rejected).toBe(0);
    });

    it("sends RateLimit headers, but none on responses Cloudflare may cache", async () => {
        const { hit } = harness("enforce");
        const live = await hit("/x");
        expect(live.headers.get("RateLimit-Limit")).toBe(String(TIERS.public.burst));
        expect(live.headers.get("RateLimit-Remaining")).toBe(String(TIERS.public.burst - 1));
        const cached = await hit("/cached");
        expect(cached.headers.get("RateLimit-Limit")).toBeNull();
        expect(cached.headers.get("RateLimit-Remaining")).toBeNull();
    });
});

describe("shadow mode", () => {
    it("keeps the old window in charge while the buckets only count", async () => {
        const { hit, limiter, waits } = harness("shadow");
        for (let i = 0; i < 3; i++) expect((await hit()).status).toBe(200);
        const limited = await hit();
        expect(limited.status).toBe(429);
        expect(waits).toEqual([]);
        const snap = limiter.snapshot();
        expect(snap.mode).toBe("shadow");
        expect(snap.tiers.public.requests).toBe(4);
        expect(snap.legacyRejected).toBe(1);
    });

    it("records what the buckets would hold and reject without waiting", async () => {
        const { hit, limiter, waits } = harness("shadow", { legacyMax: 10_000 });
        for (let i = 0; i < TIERS.public.burst + 10; i++) await hit();
        const t = limiter.snapshot().tiers.public;
        expect(t.held).toBeGreaterThan(0);
        expect(t.rejected).toBeGreaterThan(0);
        expect(waits).toEqual([]);
        expect(limiter.snapshot().topRejected[0]).toMatchObject({ client: "198.51.100.5", tier: "public" });
    });
});

describe("legacy window", () => {
    it("says how long until the oldest request leaves the window", async () => {
        const { hit, advance } = harness("legacy");
        for (let i = 0; i < 3; i++) await hit();
        advance(15_000);
        const res = await hit();
        expect(res.status).toBe(429);
        expect(res.headers.get("Retry-After")).toBe("45");
    });

    it("lets internal keys skip it and strips its headers from cacheable responses", async () => {
        const { hit } = harness("legacy");
        for (let i = 0; i < 10; i++) expect((await hit("/x", { "x-internal-secret": KEY })).status).toBe(200);
        const cached = await hit("/cached");
        expect(cached.headers.get("X-RateLimit-Remaining")).toBeNull();
        const live = await hit("/x");
        expect(live.headers.get("X-RateLimit-Remaining")).toBe("1");
    });
});

describe("top paths", () => {
    it("folds ids, addresses, names and burn ids into one route", () => {
        expect(routeShape("/normie/123/image.svg")).toBe("/normie/:n/image.svg");
        expect(routeShape("/history/burns/2-6")).toBe("/history/burns/:n-:n");
        expect(routeShape("/holders/0xAbC0000000000000000000000000000000000001")).toBe("/holders/:hex");
        expect(routeShape("/rarity/holder/vitalik.eth")).toBe("/rarity/holder/:ens");
        expect(routeShape("/agents/metadata/42.json")).toBe("/agents/metadata/:n.json");
        expect(routeShape("/market/stats")).toBe("/market/stats");
    });

    it("counts each internal key's routes, with tokens and the route's own errors", async () => {
        const { hit, limiter } = harness("shadow", { legacyMax: 10_000 });
        for (let i = 0; i < 5; i++) await hit(`/history/burns/${i}`, { "x-internal-secret": KEY });
        await hit("/normie/1/image.svg", { "x-internal-secret": KEY });
        await hit("/normie/2/image.svg", { "x-internal-secret": KEY });
        await hit("/normie/images?ids=1,2,3", { origin: "https://www.normies.art" });
        const { topPaths } = limiter.snapshot();
        expect(topPaths.site).toEqual([
            { path: "/history/burns/:n", requests: 5, tokens: 5, errors: 5 },
            { path: "/normie/:n/image.svg", requests: 2, tokens: 2, errors: 0 },
        ]);
        expect(topPaths.website).toEqual([{ path: "/normie/images", requests: 1, tokens: 2, errors: 0 }]);
    });

    it("keeps a bounded number of routes per group", async () => {
        const { hit, limiter } = harness("shadow", { legacyMax: 10_000 });
        for (let i = 0; i < 310; i++) await hit(`/r${i}`, { "x-internal-secret": KEY });
        const rows = limiter.snapshot().topPaths.site;
        expect(rows.length).toBe(15);
        expect(rows[0]).toMatchObject({ path: "(other)", requests: 10 });
    });
});

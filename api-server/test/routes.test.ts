import { beforeAll, describe, expect, it, vi } from "vitest";
import { Hono } from "hono";

// Config is evaluated at import time: point everything at fake hosts and enable
// the Pixel Market stack before the routes load.
process.env.PONDER_API_URL = "http://ponder.test";
process.env.RPC_URL = "http://rpc.test";
process.env.LEDGER_ADDRESS = "0x0000000000000000000000000000000000000001";
process.env.CANVAS_V2_ADDRESS = "0x0000000000000000000000000000000000000002";
process.env.CANVAS_STORAGE_V2_ADDRESS = "0x0000000000000000000000000000000000000003";
process.env.MARKET_ADDRESS = "0x0000000000000000000000000000000000000004";
process.env.ARENA_STORAGE_ADDRESS = "0x0000000000000000000000000000000000000005";

const SELLER = "0x00000000000000000000000000000000000000aa";
const HOLDER = "0x00000000000000000000000000000000000000bb";

// Canned indexer responses keyed by path (query string stripped).
const ponder: Record<string, unknown> = {
    [`/pixels/balance/${HOLDER}`]: { address: HOLDER, balance: "120", updatedBlock: "100" },
    [`/tokens/${HOLDER}`]: ["7", "9"],
    "/pixels/token/batch": {
        tokens: {
            "7": { tokenId: "7", attached: "64", locked: "10", free: "54", gridSize: 60, baseCleared: false, migrated: true, customized: true, blockNumber: "90" },
            "9": { tokenId: "9", attached: "0", locked: "0", free: "0", gridSize: 40, baseCleared: true, migrated: false, customized: false, blockNumber: "80" },
        },
    },
    "/pixels/supply": { totalWallet: "500", totalAttached: "3000", totalMigrated: 12, wallets: 3, blockNumber: "100", timestamp: "1700000000" },
    "/market/listings": {
        listings: [
            { listingId: "1", seller: SELLER, pricePerPixel: "1000000000000000", amount: 100, remaining: 60, partialFill: true, expiry: "0", status: "active" },
        ],
        hasMore: false,
    },
    "/market/listings/1": { listingId: "1", seller: SELLER, status: "active", fills: [] },
    "/market/stats": { volumeWei: "1", feesWei: "0", pixelsTraded: "1", fills: 1, listings: 1, feeBps: 1000, revenueShareBps: 5000, paused: false, activeListings: 1, pixelsListed: 60, bestAskWei: "1000000000000000" },
    "/market/candles": { interval: "1h", candles: [] },
    "/canvas-state/7": {
        tokenId: "7", actionPoints: "64", customized: true, delegate: "0x0000000000000000000000000000000000000000",
        delegateSetBy: "0x0000000000000000000000000000000000000000", latestTransformBitmap: null,
        gridSize: 60, baseCleared: false, migrated: true, lockedPixels: 10, blockNumber: "90", timestamp: "1", txHash: "0x01",
    },
    "/canvas/sinks": { events: [], hasMore: false },
    "/arena/status": { indexed: true, currentRound: 3, round: { round: 3, status: "open" }, normies: { registered: 12, active: 10, short: 2, cleared: 0 } },
    "/arena/rounds": { rounds: [{ round: 3, status: "open", pool: "250", players: 20 }], hasMore: false },
    "/arena/rounds/3": { round: 3, status: "open", pool: "250", players: 20 },
    "/arena/rounds/3/players": { round: 3, status: "open", total: 1, players: [{ tokenId: "7", played: true, charged: "1" }], hasMore: false },
    "/arena/rounds/2/winners": { round: 2, status: "ended", total: 1, winners: [{ tokenId: "9", payoutOrder: 1, prize: "100" }], hasMore: false },
    "/arena/rounds/2/refunds": { round: 2, status: "ended", price: "1", total: 1, refundees: [{ tokenId: "7", refund: "1" }], hasMore: false },
    "/arena/registered": { state: "all", total: 12, normies: [{ tokenId: "7", state: "active", balance: "5" }], hasMore: false },
    "/arena/normie/7": { tokenId: "7", balance: "5", state: "active", registered: true, inCurrentRound: true },
    "/arena/normie/7/rounds": { tokenId: "7", rounds: [], hasMore: false },
    [`/arena/holder/${HOLDER}`]: { address: HOLDER, balance: "5", registered: 1, active: 1, short: 0, normies: [{ tokenId: "7" }] },
    "/arena/activity": { events: [], hasMore: false },
    "/arena/skins": { total: 1, pixels: "5", purchases: [{ id: "v3-1", source: "v3", purchaseId: "1", tokenId: "7", price: "5" }], hasMore: false },
    "/arena/skins/normie/7": { tokenId: "7", count: 1, purchases: [] },
    "/arena/records": { sort: "wins", normies: [{ tokenId: "9", wins: 2 }], hasMore: false },
};

const calls: string[] = [];

beforeAll(() => {
    vi.stubGlobal("fetch", async (input: string | URL | Request) => {
        const url = new URL(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
        calls.push(url.pathname + url.search);
        const body = ponder[url.pathname];
        if (body === undefined) return new Response(JSON.stringify({ error: "not found" }), { status: 404 });
        return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
    });
});

async function buildApp() {
    const { pixels } = await import("../src/routes/pixels.js");
    const { market } = await import("../src/routes/market.js");
    const { canvas } = await import("../src/routes/canvas.js");
    const { arena } = await import("../src/routes/arena.js");
    return new Hono().route("/pixels", pixels).route("/market", market).route("/canvas", canvas).route("/arena", arena);
}

describe("/pixels", () => {
    it("combines the wallet balance with the pixels on owned Normies", async () => {
        const app = await buildApp();
        const res = await app.request(`/pixels/balance/${HOLDER}`);
        expect(res.status).toBe(200);
        const body = await res.json();
        expect(body.balance).toBe("120");
        expect(body.attached).toBe("64");
        expect(body.locked).toBe("10");
        expect(body.free).toBe("54");
        expect(body.tokens).toHaveLength(2);
        expect(body.tokens[1]).toMatchObject({ tokenId: "9", baseCleared: true });
    });

    it("rejects malformed addresses", async () => {
        const app = await buildApp();
        expect((await app.request("/pixels/balance/nope")).status).toBe(400);
    });

    it("proxies the supply", async () => {
        const app = await buildApp();
        const body = await (await app.request("/pixels/supply")).json();
        expect(body.totalAttached).toBe("3000");
    });
});

describe("/market", () => {
    it("validates filters and forwards them to the indexer", async () => {
        const app = await buildApp();
        calls.length = 0;
        const res = await app.request(`/market/listings?sort=price-desc&seller=${SELLER}&partial=true&limit=10`);
        expect(res.status).toBe(200);
        expect(calls[0]).toContain("/market/listings?");
        expect(calls[0]).toContain("sort=price-desc");
        expect(calls[0]).toContain(`seller=${SELLER}`);
        expect(calls[0]).toContain("partial=true");
        expect((await app.request("/market/listings?sort=sideways")).status).toBe(400);
        expect((await app.request("/market/listings?status=weird")).status).toBe(400);
        expect((await app.request("/market/listings/abc")).status).toBe(400);
        expect((await app.request("/market/candles?interval=5m")).status).toBe(400);
    });

    it("serves a listing and the stats", async () => {
        const app = await buildApp();
        const listing = await (await app.request("/market/listings/1")).json();
        expect(listing.seller).toBe(SELLER);
        const stats = await (await app.request("/market/stats")).json();
        expect(stats.bestAskWei).toBe("1000000000000000");
    });
});

describe("/canvas/token/:id/pixels", () => {
    it("splits attached pixels into locked and free", async () => {
        const app = await buildApp();
        const body = await (await app.request("/canvas/token/7/pixels")).json();
        expect(body).toMatchObject({ attached: 64, locked: 10, free: 54, gridSize: 60, level: 7, migrated: true });
    });
});

describe("/arena", () => {
    it("proxies status, rounds, registered Normies and Normie state", async () => {
        const app = await buildApp();
        expect((await (await app.request("/arena/status")).json()).normies.registered).toBe(12);
        expect((await (await app.request("/arena/rounds/3")).json()).pool).toBe("250");
        expect((await (await app.request("/arena/rounds/3/players")).json()).players[0].played).toBe(true);
        expect((await (await app.request("/arena/rounds/2/winners")).json()).winners[0].payoutOrder).toBe(1);
        expect((await (await app.request("/arena/rounds/2/refunds")).json()).refundees[0].refund).toBe("1");
        expect((await (await app.request("/arena/registered")).json()).normies[0].state).toBe("active");
        expect((await (await app.request("/arena/normie/7")).json()).inCurrentRound).toBe(true);
        expect((await (await app.request("/arena/normie/7/rounds")).json()).rounds).toEqual([]);
        expect((await (await app.request(`/arena/holder/${HOLDER.toUpperCase().replace("0X", "0x")}`)).json()).active).toBe(1);
        expect((await (await app.request("/arena/skins/normie/7")).json()).count).toBe(1);
        expect((await (await app.request("/arena/records?sort=wins")).json()).normies[0].wins).toBe(2);
    });

    it("forwards filters and paging to the indexer", async () => {
        const app = await buildApp();
        calls.length = 0;
        await app.request("/arena/rounds?status=ended&sort=asc&limit=5");
        expect(calls[0]).toBe("/arena/rounds?limit=5&offset=0&status=ended&sort=asc");
        await app.request("/arena/records?sort=wins&offset=10");
        expect(calls[1]).toBe("/arena/records?limit=50&offset=10&sort=wins");
        await app.request(`/arena/activity?kind=refund&source=v3&round=3&tokenId=7&address=${HOLDER}`);
        expect(calls[2]).toBe(`/arena/activity?limit=50&offset=0&kind=refund&source=v3&round=3&tokenId=7&address=${HOLDER}`);
        await app.request("/arena/normie/7/activity?limit=2");
        expect(calls[3]).toBe("/arena/activity?limit=2&offset=0&tokenId=7");
        await app.request(`/arena/skins?buyer=${SELLER}`);
        expect(calls[4]).toBe(`/arena/skins?limit=50&offset=0&buyer=${SELLER}`);
        await app.request("/arena/rounds/3/players");
        expect(calls[5]).toBe("/arena/rounds/3/players?limit=500&offset=0");
        await app.request("/arena/rounds/3/players?limit=5000&offset=1000");
        expect(calls[6]).toBe("/arena/rounds/3/players?limit=1000&offset=1000");
        await app.request("/arena/registered?state=short&limit=20");
        expect(calls[7]).toBe("/arena/registered?limit=20&offset=0&state=short");
        await app.request("/arena/rounds/2/refunds");
        expect(calls[8]).toBe("/arena/rounds/2/refunds?limit=500&offset=0");
    });

    it("validates parameters", async () => {
        const app = await buildApp();
        for (const path of [
            "/arena/rounds?status=weird",
            "/arena/rounds?status=settled",
            "/arena/rounds?status=finished",
            "/arena/rounds/0",
            "/arena/rounds/abc",
            "/arena/rounds/abc/players",
            "/arena/rounds/-1/winners",
            "/arena/rounds/x/refunds",
            "/arena/registered?state=waiting",
            "/arena/normie/10000",
            "/arena/normie/x/rounds",
            "/arena/holder/nope",
            "/arena/activity?kind=weird",
            "/arena/activity?kind=entry",
            "/arena/activity?source=v1",
            "/arena/activity?round=0",
            "/arena/activity?tokenId=99999",
            "/arena/activity?address=nope",
            "/arena/skins?buyer=nope",
            "/arena/skins/normie/abc",
            "/arena/records?sort=score",
        ]) {
            expect((await app.request(path)).status, path).toBe(400);
        }
    });

    it("no longer serves the v2 line routes", async () => {
        const app = await buildApp();
        expect((await app.request("/arena/queue")).status).toBe(404);
        expect((await app.request("/arena/leaderboard")).status).toBe(404);
    });

    it("answers 404 for a round the indexer has no record of", async () => {
        const app = await buildApp();
        expect((await app.request("/arena/rounds/99")).status).toBe(404);
        expect((await app.request("/arena/rounds/99/players")).status).toBe(404);
        expect((await app.request("/arena/rounds/99/winners")).status).toBe(404);
        expect((await app.request("/arena/rounds/99/refunds")).status).toBe(404);
    });
});

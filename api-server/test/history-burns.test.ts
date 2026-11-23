import { describe, expect, it, vi } from "vitest";
import { Hono } from "hono";

// Config is evaluated at import time and the chain client needs an RPC; CI has no .env.
process.env.RPC_URL = "http://rpc.test";

// The indexer's commitments: V2 ids restarted at 0, so 1 exists on both canvases and 538 only on V1.
const known: Record<string, { id: string; commitId: string; contractVersion: number }> = {
    "2-1": { id: "2-1", commitId: "1", contractVersion: 2 },
    "1-1": { id: "1-1", commitId: "1", contractVersion: 1 },
    "1-538": { id: "1-538", commitId: "538", contractVersion: 1 },
};
const asked: string[] = [];

vi.mock("../src/services/ponder-data.js", async (importOriginal) => ({
    ...(await importOriginal<typeof import("../src/services/ponder-data.js")>()),
    getBurnCommitment: vi.fn(async (commitId: string, version?: 1 | 2) => {
        const key = `${version ?? 2}-${commitId}`;
        asked.push(key);
        if (!known[key]) throw new Error(`Ponder API 404: {"error":"Commitment not found"}`);
        return known[key];
    }),
}));

const { history } = await import("../src/routes/history.js");
const { errorHandler } = await import("../src/middleware/error-handler.js");
const app = new Hono().route("/history", history);
app.onError(errorHandler);

async function get(path: string) {
    asked.length = 0;
    const res = await app.request(path);
    return { status: res.status, body: (await res.json()) as Record<string, unknown>, asked: [...asked] };
}

describe("GET /history/burns/:commitId", () => {
    it("a bare id prefers the newest canvas", async () => {
        const r = await get("/history/burns/1");
        expect(r.status).toBe(200);
        expect(r.body.id).toBe("2-1");
        expect(r.asked).toEqual(["2-1"]);
    });

    it("a bare id only on the old canvas falls back to it", async () => {
        const r = await get("/history/burns/538");
        expect(r.status).toBe(200);
        expect(r.body.id).toBe("1-538");
        expect(r.asked).toEqual(["2-538", "1-538"]);
    });

    it("a versioned id names one canvas exactly", async () => {
        expect((await get("/history/burns/1-1")).body.id).toBe("1-1");
        expect((await get("/history/burns/1?version=1")).body.id).toBe("1-1");
    });

    it("an id on neither canvas is a 404, not a 502", async () => {
        const r = await get("/history/burns/9999");
        expect(r.status).toBe(404);
        expect((await get("/history/burns/2-538")).status).toBe(404);
    });

    it("rejects malformed and contradictory ids before asking the indexer", async () => {
        for (const path of ["/history/burns/abc", "/history/burns/3-1", "/history/burns/1-1?version=2", "/history/burns/1?version=7"]) {
            const r = await get(path);
            expect(r.status, path).toBe(400);
            expect(r.asked, path).toEqual([]);
        }
    });
});

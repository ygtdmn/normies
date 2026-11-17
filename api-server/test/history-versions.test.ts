import { describe, expect, it, vi } from "vitest";

// A 40x40 base with only the top-left pixel on, and one version whose overlay flips the next pixel.
const base = new Uint8Array(200);
base[0] = 0b1000_0000;
const overlay = `0x40${"00".repeat(199)}`;

vi.mock("../src/services/ponder-data.js", async (importOriginal) => ({
    ...(await importOriginal<typeof import("../src/services/ponder-data.js")>()),
    getTransformHistory: vi.fn(async () => [
        {
            id: "a", tokenId: "7", transformer: "0x1", changeCount: 1, newPixelCount: 99,
            transformBitmap: overlay, gridSize: 40, cleared: false,
            blockNumber: "100", timestamp: "1", txHash: "0xaa",
        },
        {
            id: "b", tokenId: "7", transformer: "0x1", changeCount: 0, newPixelCount: 5,
            transformBitmap: null, gridSize: 40, cleared: false,
            blockNumber: "101", timestamp: "2", txHash: "0xbb",
        },
    ]),
}));
vi.mock("../src/services/zombie-data.js", async (importOriginal) => ({
    ...(await importOriginal<typeof import("../src/services/zombie-data.js")>()),
    getZombieInfo: vi.fn(async () => null),
    getBaseImageDataAtBlock: vi.fn(async () => base),
}));
vi.mock("../src/services/canvas-data.js", async (importOriginal) => ({
    ...(await importOriginal<typeof import("../src/services/canvas-data.js")>()),
    getBaseClearedBlock: vi.fn(async () => null),
}));

const { history } = await import("../src/routes/history.js");

async function versions(query = "") {
    const res = await history.request(`/normie/7/versions${query}`);
    expect(res.status).toBe(200);
    return (await res.json()) as Array<Record<string, unknown>>;
}

describe("GET /normie/:id/versions", () => {
    it("leaves pixels out unless asked", async () => {
        const rows = await versions();
        expect(rows[0]).not.toHaveProperty("pixels");
        expect(rows[0].newPixelCount).toBe(2);
    });

    it("adds each version's composited art with pixels=1", async () => {
        const [first, second] = await versions("?pixels=1");
        expect(first.pixels).toBe(`11${"0".repeat(1598)}`);
        expect(first.newPixelCount).toBe(2);
        // No bitmap and not a reset: nothing to draw, and the indexer's count stands.
        expect(second).not.toHaveProperty("pixels");
        expect(second.newPixelCount).toBe(5);
    });
});

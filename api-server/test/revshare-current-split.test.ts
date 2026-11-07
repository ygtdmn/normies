import { beforeAll, describe, expect, it } from "vitest";

// Config is evaluated at import time.
process.env.PONDER_API_URL = "http://ponder.test";
process.env.RPC_URL = "http://rpc.test";
let currentSplit: typeof import("../src/services/revshare-data.js").currentSplit;
beforeAll(async () => {
    ({ currentSplit } = await import("../src/services/revshare-data.js"));
});

const since = (marketToPool: string, royaltiesToPool: string) => ({
    fromBlock: "100",
    sources: {
        market: { fills: 3, volumeWei: "0", feesWei: "0", toPoolWei: marketToPool },
        royalties: { releases: 1, toPoolWei: royaltiesToPool, toTeamWei: royaltiesToPool },
    },
});

describe("currentSplit", () => {
    it("splits the available pool into market fees, royalties (released + waiting) and the rest", () => {
        const split = currentSplit(1000n, 200n, since("500", "250"));
        expect(split).toEqual({
            fromBlock: "100",
            marketFeesWei: "500",
            marketFills: 3,
            royaltiesReleasedWei: "250",
            royaltiesPendingWei: "200",
            royaltiesWei: "450",
            otherWei: "50",
        });
    });

    it("clamps the rest at zero when summed fees run a few wei over the pool", () => {
        expect(currentSplit(700n, 0n, since("702", "0")).otherWei).toBe("0");
    });
});

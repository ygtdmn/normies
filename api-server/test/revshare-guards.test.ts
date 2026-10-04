import { describe, expect, it } from "vitest";
import type { EpochFile } from "../src/revshare/build.js";
import { REVSHARE_CONFIG, configHash } from "../src/revshare/config.js";
import {
    epochEndBlock,
    epochMismatches,
    postedMismatches,
    prePostProblems,
    requireIndependentVerifier,
    type PoolState,
} from "../src/revshare/guards.js";

const ROOT = "0x1111111111111111111111111111111111111111111111111111111111111111";

const epoch = (over: Partial<EpochFile> = {}): EpochFile => ({
    epochId: "3",
    fromBlock: "1001",
    toBlock: "2000",
    amount: "1000",
    total: "990",
    root: ROOT,
    configHash: configHash(REVSHARE_CONFIG),
    config: REVSHARE_CONFIG,
    chainId: 1,
    addresses: {},
    excluded: [],
    sampleBlocks: ["1200", "1500", "1900"],
    leaves: [],
    ...over,
});

const pool = (over: Partial<PoolState> = {}): PoolState => ({
    nextEpochId: 3n,
    cursorToBlock: 1000n,
    unallocated: 1000n,
    paused: false,
    unopened: null,
    ...over,
});

describe("requireIndependentVerifier", () => {
    it("refuses to post without a second RPC", () => {
        expect(() => requireIndependentVerifier("https://a.example/v2/k", undefined)).toThrow(/RPC_URL_VERIFY is not set/);
        expect(() => requireIndependentVerifier("https://a.example/v2/k", "")).toThrow(/RPC_URL_VERIFY is not set/);
    });

    it("refuses the same endpoint twice, ignoring case and a trailing slash", () => {
        expect(() => requireIndependentVerifier("https://A.example/v2/k", "https://a.example/v2/k/")).toThrow(/same endpoint/);
    });

    it("accepts an independent provider", () => {
        expect(requireIndependentVerifier("https://a.example/v2/k", "https://b.example/k")).toBe("https://b.example/k");
    });
});

describe("epochMismatches", () => {
    it("passes two identical builds", () => {
        expect(epochMismatches(epoch(), epoch())).toEqual([]);
    });

    it("catches a different amount even when the root agrees", () => {
        expect(epochMismatches(epoch(), epoch({ amount: "999" }))).toEqual(["amount: 1000 vs 999"]);
    });

    it("catches a different root, total, sample set and config", () => {
        const other = epoch({
            root: "0x2222222222222222222222222222222222222222222222222222222222222222",
            total: "989",
            sampleBlocks: ["1200", "1500", "1901"],
            configHash: "0x3333333333333333333333333333333333333333333333333333333333333333",
        });
        const fields = epochMismatches(epoch(), other).map((m) => m.split(":")[0]);
        expect(fields).toEqual(["total", "configHash", "sampleBlocks", "root"]);
    });
});

describe("prePostProblems", () => {
    it("refuses while the previous epoch has not opened, so a cancel can never strand an older range", () => {
        const problems = prePostProblems(epoch(), pool({ unopened: { id: 2n, claimableAt: 1_790_000_000n } }));
        expect(problems).toHaveLength(1);
        expect(problems[0]).toMatch(/epoch 2 has not opened for claims yet \(opens 2026-09-21T/);
    });

    it("passes an epoch that fits the pool exactly", () => {
        expect(prePostProblems(epoch(), pool())).toEqual([]);
    });

    it("refuses an epoch id the pool has moved past (every leaf would be unclaimable)", () => {
        expect(prePostProblems(epoch(), pool({ nextEpochId: 4n }))).toEqual([
            "epoch id 3 is not the pool's next id 4; every leaf would be unclaimable",
        ]);
    });

    it("refuses a gap or overlap with the last posted range", () => {
        expect(prePostProblems(epoch(), pool({ cursorToBlock: 1500n }))[0]).toMatch(/last posted epoch ended at 1500/);
    });

    it("lets the first epoch start anywhere", () => {
        expect(prePostProblems(epoch({ epochId: "1" }), pool({ nextEpochId: 1n, cursorToBlock: 0n }))).toEqual([]);
    });

    it("refuses when the unreserved ETH has gone down since the build", () => {
        expect(prePostProblems(epoch(), pool({ unallocated: 989n }))[0]).toMatch(/pays 990 wei but the pool has only 989/);
    });

    it("refuses a paused pool and leaves that add up to more than the amount", () => {
        expect(prePostProblems(epoch({ total: "1001" }), pool({ paused: true, unallocated: 5000n }))).toEqual([
            "the pool is paused for posting",
            "leaves add up to 1001, more than the epoch amount 1000",
        ]);
    });
});

describe("postedMismatches", () => {
    const posted = { root: ROOT as `0x${string}`, amount: 990n, fromBlock: 1001n, toBlock: 2000n };

    it("passes when the pool recorded exactly the file", () => {
        expect(postedMismatches(epoch(), posted)).toEqual([]);
        expect(postedMismatches(epoch(), { ...posted, root: ROOT.toUpperCase().replace("0X", "0x") as `0x${string}` })).toEqual([]);
    });

    it("compares the posted amount with the leaves' total, not the epoch amount", () => {
        expect(postedMismatches(epoch(), { ...posted, amount: 1000n })).toEqual(["amount: file total 990, pool 1000"]);
    });
});

describe("epochEndBlock", () => {
    it("never passes the finalized block", () => {
        expect(epochEndBlock(10_000n, 9_900n, 64n)).toBe(9_900n);
    });

    it("stays at least `finality` deep when finality is ahead of that", () => {
        expect(epochEndBlock(10_000n, 9_990n, 64n)).toBe(9_936n);
    });

    it("falls back to depth alone where the finalized tag is not served", () => {
        expect(epochEndBlock(10_000n, null, 64n)).toBe(9_936n);
    });
});

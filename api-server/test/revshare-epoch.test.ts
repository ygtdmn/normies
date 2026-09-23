import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { buildPayouts, scoreSample } from "../src/revshare/epoch.js";
import { buildTree } from "../src/revshare/merkle.js";
import { pickSampleBlock, sampleWindows } from "../src/revshare/sample.js";
import type { WalletState } from "../src/revshare/score.js";

const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const C = "0x00000000000000000000000000000000000000c3";

const holder = (address: string, tokens: number): WalletState => ({ address, tokens, pixels: 0n });

describe("scoreSample", () => {
    it("drops excluded addresses and zero scores", () => {
        const scores = scoreSample([holder(A, 1), holder(B, 1), holder(C, 0)], new Set([B]));
        expect([...scores.keys()]).toEqual([A]);
    });
});

describe("buildPayouts", () => {
    it("splits each slice by that sample's scores, floors, and leaves the dust in the pool", () => {
        const sample = new Map([[A, 1n], [B, 1n], [C, 1n]]);
        const { payouts, total } = buildPayouts([sample], 100n);
        expect(payouts.map((p) => p.amount)).toEqual([33n, 33n, 33n]);
        expect(total).toBe(99n);
    });

    it("is time weighted: one sample out of four earns a quarter of the share", () => {
        const both = new Map([[A, 1n], [B, 1n]]);
        const onlyA = new Map([[A, 1n]]);
        const { payouts } = buildPayouts([both, onlyA, onlyA, onlyA], 800n);
        expect(payouts).toEqual([
            { account: A, amount: 700n },
            { account: B, amount: 100n },
        ]);
    });

    it("skips a sample nobody scored in, keeping its slice unallocated", () => {
        const { payouts, total } = buildPayouts([new Map(), new Map([[A, 5n]])], 1000n);
        expect(payouts).toEqual([{ account: A, amount: 500n }]);
        expect(total).toBe(500n);
    });

    it("orders payouts by address so indexes are reproducible", () => {
        const { payouts } = buildPayouts([new Map([[C, 1n], [A, 1n], [B, 1n]])], 300n);
        expect(payouts.map((p) => p.account)).toEqual([A, B, C]);
    });
});

describe("sampling", () => {
    it("cuts UTC-aligned windows and clips them to the epoch", () => {
        const day = 86_400;
        const windows = sampleWindows(10 * day + 3_600, 11 * day + 7_200, 4);
        expect(windows[0]).toEqual({ start: 10 * day + 3_600, end: 10 * day + 21_600 });
        expect(windows.at(-1)).toEqual({ start: 11 * day, end: 11 * day + 7_200 });
        expect(windows).toHaveLength(5);
    });

    it("picks a block inside the window, fixed by the trailing hashes", () => {
        const hashes = [`0x${"11".repeat(32)}`, `0x${"22".repeat(32)}`] as `0x${string}`[];
        const pick = pickSampleBlock(1000n, 1099n, hashes);
        expect(pick >= 1000n && pick <= 1099n).toBe(true);
        expect(pickSampleBlock(1000n, 1099n, hashes)).toBe(pick);
        expect(pickSampleBlock(1000n, 1099n, [hashes[1], hashes[0]])).not.toBe(pick);
        expect(pickSampleBlock(7n, 7n, hashes)).toBe(7n);
    });
});

/**
 * The same epoch the forge test NormiesRevShareParityTest claims against the real pool contract. If the TypeScript
 * tree and the Solidity verification ever disagree, one of the two suites fails.
 */
describe("Merkle parity fixture", () => {
    const fixturePath = resolve(dirname(fileURLToPath(import.meta.url)), "../../test/fixtures/revshare-epoch.json");

    it("matches the committed fixture", () => {
        const payouts = [
            { account: A as `0x${string}`, amount: 1_000_000_000_000_000_000n },
            { account: B as `0x${string}`, amount: 250_000_000_000_000_000n },
            { account: C as `0x${string}`, amount: 1n },
            { account: "0x00000000000000000000000000000000000000d4" as `0x${string}`, amount: 42_000_000_000n },
            { account: "0x00000000000000000000000000000000000000e5" as `0x${string}`, amount: 7_500_000_000_000_000n },
        ];
        const { root, leaves } = buildTree(1n, payouts);
        const generated = {
            epochId: "1",
            root,
            total: payouts.reduce((s, p) => s + p.amount, 0n).toString(),
            leaves,
        };
        if (!existsSync(fixturePath) || process.env.UPDATE_FIXTURES) {
            mkdirSync(dirname(fixturePath), { recursive: true });
            writeFileSync(fixturePath, `${JSON.stringify(generated, null, 2)}\n`);
        }
        expect(JSON.parse(readFileSync(fixturePath, "utf8"))).toEqual(generated);
    });

    it("handles a single payout with an empty proof", () => {
        const { root, leaves } = buildTree(3n, [{ account: A as `0x${string}`, amount: 5n }]);
        expect(leaves[0].proof).toEqual([]);
        expect(root).toMatch(/^0x[0-9a-f]{64}$/);
    });
});

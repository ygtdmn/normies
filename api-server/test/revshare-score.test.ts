import { describe, expect, it } from "vitest";
import { REVSHARE_CONFIG, configHash } from "../src/revshare/config.js";
import { boostPct, bracket100, scoreWallet, type WalletState } from "../src/revshare/score.js";

/** Serc's formula as the site's tiers.js computes it, in floats. Every pixel weighs the same. */
function referenceScore(tokens: number, pixels: number): number {
    let bracket = 0;
    for (const [min, x] of [[1, 1], [2, 1.15], [5, 1.3], [10, 1.45], [25, 1.6], [50, 1.75]]) if (tokens >= min) bracket = x;
    let boost = 0;
    for (const [min, b] of [[15, 0.15], [100, 0.35], [500, 0.6], [1500, 1]]) if (pixels >= min) boost = b;
    if (tokens < 1) return 0;
    return (tokens * bracket + pixels / 5) * (1 + boost);
}

const wallet = (tokens: number, pixels: number): WalletState => ({
    address: "0x00000000000000000000000000000000000000a1",
    tokens,
    pixels: BigInt(pixels),
});

describe("brackets and boost", () => {
    it("steps at the published thresholds", () => {
        expect([0, 1, 2, 4, 5, 9, 10, 24, 25, 49, 50, 400].map((n) => bracket100(n))).toEqual([
            0, 100, 115, 115, 130, 130, 145, 145, 160, 160, 175, 175,
        ]);
        expect([0n, 14n, 15n, 99n, 100n, 499n, 500n, 1499n, 1500n].map((p) => boostPct(p, 1))).toEqual([
            0, 0, 15, 15, 35, 35, 60, 60, 100,
        ]);
        expect(boostPct(5000n, 0)).toBe(0);
    });
});

describe("scoreWallet", () => {
    it("matches the site's float formula x100,000", () => {
        const cases: [number, number][] = [[1, 0], [2, 15], [5, 100], [10, 500], [5, 3977], [50, 1500], [3, 250], [0, 400]];
        for (const [tokens, pixels] of cases) {
            const { score } = scoreWallet(wallet(tokens, pixels));
            expect(Number(score)).toBe(Math.round(referenceScore(tokens, pixels) * 100_000));
        }
    });

    it("weighs every pixel the same: five full pixels equal one bare Normie", () => {
        expect(scoreWallet(wallet(1, 0)).score).toBe(100_000n);
        expect(scoreWallet(wallet(1, 5)).pixelPoints).toBe(scoreWallet(wallet(1, 0)).normiePoints);
        expect(scoreWallet(wallet(1, 2000)).pixelPoints).toBe(2n * scoreWallet(wallet(1, 1000)).pixelPoints);
    });

    it("reproduces the article's worked example: 10 Normies and 500 pixels score 183.2", () => {
        const s = scoreWallet(wallet(10, 500));
        expect(s.normiePoints).toBe(14_500n);
        expect(s.pixelPoints).toBe(100_000n);
        expect(s.boostPct).toBe(60);
        expect(s.score).toBe(18_320_000n);
    });

    it("scores a wallet with pixels and no Normie at zero: the Normie is the membership", () => {
        const s = scoreWallet(wallet(0, 2000));
        expect(s.pixelPoints).toBe(0n);
        expect(s.score).toBe(0n);
        expect(scoreWallet(wallet(1, 2000)).score > 0n).toBe(true);
    });
});

describe("configHash", () => {
    it("is stable and sensitive", () => {
        expect(configHash()).toBe(configHash({ ...REVSHARE_CONFIG }));
        expect(configHash({ ...REVSHARE_CONFIG, pixelFactor: 201 })).not.toBe(configHash());
    });
});

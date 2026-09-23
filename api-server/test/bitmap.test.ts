import { describe, expect, it } from "vitest";
import {
    bytesForGrid,
    composite,
    countPixels,
    embedCentered,
    fitToGrid,
    gridSizeFromLength,
    isPixelOn,
    paddingBits,
    toPixelString,
} from "../src/lib/bitmap.js";
import { computePixelDiff } from "../src/lib/diff.js";
import { renderSvg } from "../src/lib/svg.js";

function setPixel(bitmap: Uint8Array, x: number, y: number, n: number) {
    const flat = y * n + x;
    bitmap[flat >> 3] |= 0x80 >> (flat & 7);
}

describe("bitmap sizes", () => {
    it("maps grid sides to byte lengths and back", () => {
        const table: Array<[number, number]> = [[40, 200], [50, 313], [60, 450], [70, 613], [80, 800]];
        for (const [n, len] of table) {
            expect(bytesForGrid(n)).toBe(len);
            expect(gridSizeFromLength(len)).toBe(n);
        }
        expect(paddingBits(50)).toBe(4);
        expect(paddingBits(70)).toBe(4);
        expect(paddingBits(60)).toBe(0);
    });
});

describe("countPixels", () => {
    it("ignores padding bits on 50x50 and 70x70", () => {
        const b = new Uint8Array(313);
        b[0] = 0xff;
        b[312] = 0xff; // top 4 bits real, low 4 padding
        expect(countPixels(b)).toBe(12);
        expect(countPixels(b, 50)).toBe(12);
        const c = new Uint8Array(613);
        c[612] = 0x0f;
        expect(countPixels(c)).toBe(0);
    });

    it("counts a 40x40 bitmap fully", () => {
        const b = new Uint8Array(200).fill(0xff);
        expect(countPixels(b)).toBe(1600);
    });
});

describe("embedCentered", () => {
    it("moves pixels by the centring offset and keeps the count", () => {
        const src = new Uint8Array(200);
        setPixel(src, 0, 0, 40);
        setPixel(src, 39, 39, 40);
        setPixel(src, 3, 4, 40);
        for (const n of [50, 60, 70, 80]) {
            const out = embedCentered(src, 40, n);
            const off = (n - 40) / 2;
            expect(out.length).toBe(bytesForGrid(n));
            expect(countPixels(out, n)).toBe(3);
            expect(isPixelOn(out, off, off, n)).toBe(true);
            expect(isPixelOn(out, 39 + off, 39 + off, n)).toBe(true);
            expect(isPixelOn(out, 3 + off, 4 + off, n)).toBe(true);
        }
    });

    it("copies when the sizes match and refuses to shrink", () => {
        const src = new Uint8Array(200);
        src[7] = 0x3c;
        const same = embedCentered(src, 40, 40);
        expect(Array.from(same)).toEqual(Array.from(src));
        expect(same).not.toBe(src);
        expect(() => fitToGrid(new Uint8Array(313), 40)).toThrow();
    });
});

describe("composite and diff", () => {
    it("xors and reports added/removed on the transform's grid", () => {
        const base = new Uint8Array(200);
        setPixel(base, 1, 1, 40);
        const overlay = new Uint8Array(450);
        setPixel(overlay, 11, 11, 60); // erases the embedded base pixel
        setPixel(overlay, 0, 0, 60); // paints in the margin
        const diff = computePixelDiff(base, overlay);
        expect(diff.gridSize).toBe(60);
        expect(diff.removed).toEqual([{ x: 11, y: 11 }]);
        expect(diff.added).toEqual([{ x: 0, y: 0 }]);
        const image = composite(fitToGrid(base, 60), overlay);
        expect(countPixels(image, 60)).toBe(1);
        expect(toPixelString(image, 60).length).toBe(3600);
    });
});

describe("renderSvg", () => {
    it("uses the inferred grid for the viewBox and one path of runs", () => {
        const b = new Uint8Array(800);
        setPixel(b, 20, 20, 80);
        setPixel(b, 21, 20, 80);
        const svg = renderSvg(b);
        expect(svg).toContain('viewBox="0 0 80 80"');
        expect(svg).toContain('<rect width="80" height="80"');
        expect(svg).toContain("M20 20h2v1h-2z");
    });

    it("omits the path for an empty canvas", () => {
        expect(renderSvg(new Uint8Array(313))).not.toContain("<path");
    });
});

/**
 * Square monochrome bitmaps: 1 bit per pixel, row-major, MSB first. Mirrors
 * NormiesBitmap.sol. An n x n grid takes ceil(n*n/8) bytes; when n*n is not a
 * multiple of 8 the low bits of the last byte are padding (50x50 and 70x70).
 */

export const BASE_GRID = 40;

export function bytesForGrid(n: number): number {
    return (n * n + 7) >> 3;
}

export function paddingBits(n: number): number {
    return (8 - ((n * n) & 7)) & 7;
}

/** Grid side for a bitmap of `len` bytes. The five supported sizes are exact. */
export function gridSizeFromLength(len: number): number {
    switch (len) {
        case 200: return 40;
        case 313: return 50;
        case 450: return 60;
        case 613: return 70;
        case 800: return 80;
        default: return Math.max(1, Math.round(Math.sqrt(len * 8)));
    }
}

export function emptyBitmap(n: number): Uint8Array {
    return new Uint8Array(bytesForGrid(n));
}

export function popcount(bytes: Uint8Array): number {
    let count = 0;
    for (let i = 0; i < bytes.length; i++) {
        let b = bytes[i];
        while (b) {
            b &= b - 1;
            count++;
        }
    }
    return count;
}

/** "On" pixels of an n x n bitmap, ignoring padding bits. */
export function countPixels(bytes: Uint8Array, n: number = gridSizeFromLength(bytes.length)): number {
    let count = popcount(bytes);
    const pad = paddingBits(n);
    if (pad !== 0 && bytes.length > 0) {
        let tail = bytes[bytes.length - 1] & ((1 << pad) - 1);
        while (tail) {
            tail &= tail - 1;
            count--;
        }
    }
    return count;
}

export function composite(a: Uint8Array, b: Uint8Array): Uint8Array {
    const len = Math.max(a.length, b.length);
    const out = new Uint8Array(len);
    for (let i = 0; i < len; i++) out[i] = (a[i] ?? 0) ^ (b[i] ?? 0);
    return out;
}

export function isPixelOn(bytes: Uint8Array, x: number, y: number, n: number): boolean {
    const flat = y * n + x;
    return ((bytes[flat >> 3] >> (7 - (flat & 7))) & 1) === 1;
}

/** Copies a fromN x fromN bitmap into the centre of a toN x toN bitmap. */
export function embedCentered(src: Uint8Array, fromN: number, toN: number): Uint8Array {
    if (fromN === toN) return Uint8Array.from(src);
    if (toN < fromN) throw new Error(`Cannot embed ${fromN}x${fromN} into ${toN}x${toN}`);
    const out = emptyBitmap(toN);
    const off = (toN - fromN) >> 1;
    const total = fromN * fromN;
    for (let i = 0; i < src.length; i++) {
        const b = src[i];
        if (b === 0) continue;
        for (let bit = 0; bit < 8; bit++) {
            if (((b >> (7 - bit)) & 1) === 0) continue;
            const flat = i * 8 + bit;
            if (flat >= total) break;
            const o = (Math.floor(flat / fromN) + off) * toN + (flat % fromN) + off;
            out[o >> 3] |= 0x80 >> (o & 7);
        }
    }
    return out;
}

/** Brings a bitmap to `n x n`: a 40x40 layer is embedded centred, matching sizes pass through. */
export function fitToGrid(bytes: Uint8Array, n: number): Uint8Array {
    const from = gridSizeFromLength(bytes.length);
    if (from === n) return bytes;
    if (from < n) return embedCentered(bytes, from, n);
    throw new Error(`Bitmap is ${from}x${from}, larger than the ${n}x${n} grid`);
}

/** Row-major string of 0/1 characters, n*n long. */
export function toPixelString(bytes: Uint8Array, n: number = gridSizeFromLength(bytes.length)): string {
    const total = n * n;
    const chars = new Array<string>(total);
    for (let i = 0; i < total; i++) {
        chars[i] = ((bytes[i >> 3] >> (7 - (i & 7))) & 1) === 1 ? "1" : "0";
    }
    return chars.join("");
}

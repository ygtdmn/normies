import { concat, keccak256 } from "viem";

export interface SampleWindow {
    /** Unix seconds, [start, end). */
    start: number;
    end: number;
}

/**
 * UTC-aligned windows (a day cut into `perDay` equal parts) covering [from, to), clipped to it. Each window yields
 * one sample block.
 */
export function sampleWindows(from: number, to: number, perDay: number): SampleWindow[] {
    const length = Math.floor(86_400 / perDay);
    const windows: SampleWindow[] = [];
    let start = Math.floor(from / length) * length;
    while (start < to) {
        const end = start + length;
        windows.push({ start: Math.max(start, from), end: Math.min(end, to) });
        start = end;
    }
    return windows;
}

/**
 * The sample block of a window that spans blocks [first, last]. The pick is seeded by the hashes of the window's
 * last blocks, so it is fixed once the window is over and unknowable before that: nobody can arrange to hold pixels
 * only at the moment they are counted.
 */
export function pickSampleBlock(first: bigint, last: bigint, trailingHashes: `0x${string}`[]): bigint {
    if (last < first) throw new Error("Empty window");
    if (trailingHashes.length === 0) throw new Error("Need at least one block hash");
    const seed = BigInt(keccak256(concat(trailingHashes)));
    return first + (seed % (last - first + 1n));
}

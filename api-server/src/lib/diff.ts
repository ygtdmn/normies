import { GRID_SIZE } from "../config.js";

export interface PixelCoord {
    x: number;
    y: number;
}

export interface PixelDiff {
    added: PixelCoord[];
    removed: PixelCoord[];
    addedCount: number;
    removedCount: number;
    netChange: number;
}

/**
 * Compute pixel diff between original and transform bitmaps.
 * - Added: original OFF (0) AND transform ON (1) → pixel turned on by edit
 * - Removed: original ON (1) AND transform ON (1) → pixel turned off by edit
 */
export function computePixelDiff(original: Uint8Array, transform: Uint8Array): PixelDiff {
    const added: PixelCoord[] = [];
    const removed: PixelCoord[] = [];

    const totalPixels = GRID_SIZE * GRID_SIZE;
    for (let i = 0; i < totalPixels; i++) {
        const byteIndex = i >> 3;
        const bitPos = 7 - (i & 7);
        const transBit = (transform[byteIndex] >> bitPos) & 1;

        if (transBit === 1) {
            const origBit = (original[byteIndex] >> bitPos) & 1;
            const x = i % GRID_SIZE;
            const y = Math.floor(i / GRID_SIZE);
            if (origBit === 0) {
                added.push({ x, y });
            } else {
                removed.push({ x, y });
            }
        }
    }

    return {
        added,
        removed,
        addedCount: added.length,
        removedCount: removed.length,
        netChange: added.length - removed.length,
    };
}

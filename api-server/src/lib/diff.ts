import { fitToGrid, gridSizeFromLength } from "./bitmap.js";

export interface PixelCoord {
    x: number;
    y: number;
}

export interface PixelDiff {
    gridSize: number;
    added: PixelCoord[];
    removed: PixelCoord[];
    addedCount: number;
    removedCount: number;
    netChange: number;
}

/**
 * Compute pixel diff between the base art and a transform bitmap.
 * - Added: base OFF (0) AND transform ON (1) → pixel turned on by edit
 * - Removed: base ON (1) AND transform ON (1) → pixel turned off by edit
 * The base is embedded into the transform's grid when it is smaller (a 40x40
 * original on an enlarged canvas).
 */
export function computePixelDiff(original: Uint8Array, transform: Uint8Array): PixelDiff {
    const gridSize = gridSizeFromLength(transform.length);
    const base = fitToGrid(original, gridSize);
    const added: PixelCoord[] = [];
    const removed: PixelCoord[] = [];

    const totalPixels = gridSize * gridSize;
    for (let i = 0; i < totalPixels; i++) {
        const byteIndex = i >> 3;
        const bitPos = 7 - (i & 7);
        const transBit = (transform[byteIndex] >> bitPos) & 1;

        if (transBit === 1) {
            const origBit = (base[byteIndex] >> bitPos) & 1;
            const x = i % gridSize;
            const y = Math.floor(i / gridSize);
            if (origBit === 0) {
                added.push({ x, y });
            } else {
                removed.push({ x, y });
            }
        }
    }

    return {
        gridSize,
        added,
        removed,
        addedCount: added.length,
        removedCount: removed.length,
        netChange: added.length - removed.length,
    };
}

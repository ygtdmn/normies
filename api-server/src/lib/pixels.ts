import { GRID_SIZE } from "../config.js";

/**
 * Convert 200-byte monochrome bitmap to 1600-char binary string of 0s and 1s.
 * Row-major, MSB first within each byte.
 */
export function imageDataToPixelString(imageData: Uint8Array): string {
    const totalPixels = GRID_SIZE * GRID_SIZE;
    const chars = new Array<string>(totalPixels);

    for (let i = 0; i < totalPixels; i++) {
        const byteIndex = i >> 3;
        const bitPos = 7 - (i & 7);
        chars[i] = ((imageData[byteIndex] >> bitPos) & 1) === 1 ? "1" : "0";
    }

    return chars.join("");
}

export function isPixelOn(imageData: Uint8Array, x: number, y: number): boolean {
    const flatIndex = y * GRID_SIZE + x;
    const byteIndex = flatIndex >> 3;
    const bitPos = 7 - (flatIndex & 7);
    return ((imageData[byteIndex] >> bitPos) & 1) === 1;
}

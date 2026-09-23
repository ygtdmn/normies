import { gridSizeFromLength, isPixelOn as pixelOn, toPixelString } from "./bitmap.js";

/**
 * Convert a monochrome bitmap to an n*n-character binary string of 0s and 1s.
 * Row-major, MSB first within each byte. The grid side is inferred from the
 * byte length (200 -> 40, 313 -> 50, 450 -> 60, 613 -> 70, 800 -> 80).
 */
export function imageDataToPixelString(imageData: Uint8Array): string {
    return toPixelString(imageData, gridSizeFromLength(imageData.length));
}

export function isPixelOn(
    imageData: Uint8Array,
    x: number,
    y: number,
    gridSize: number = gridSizeFromLength(imageData.length),
): boolean {
    return pixelOn(imageData, x, y, gridSize);
}

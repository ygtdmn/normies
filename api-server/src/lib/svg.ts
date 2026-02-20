import { GRID_SIZE, SVG_OUTPUT_SIZE, BG_COLOR, PIXEL_COLOR } from "../config.js";
import { isPixelOn } from "./pixels.js";

/**
 * Generate SVG from 200-byte monochrome bitmap.
 * Mirrors NormiesRendererV3._renderSvg exactly:
 * - viewBox="0 0 40 40", width/height="1000"
 * - shape-rendering="crispEdges"
 * - Background rect #e3e5e4, pixel rects #48494b
 * - Row-scan RLE: consecutive "on" pixels merged into wider rects
 */
export function renderSvg(imageData: Uint8Array): string {
    const parts: string[] = [];

    parts.push(
        `<svg xmlns="http://www.w3.org/2000/svg" width="${SVG_OUTPUT_SIZE}" height="${SVG_OUTPUT_SIZE}" viewBox="0 0 ${GRID_SIZE} ${GRID_SIZE}" shape-rendering="crispEdges">`
    );
    parts.push(`<rect width="${GRID_SIZE}" height="${GRID_SIZE}" fill="${BG_COLOR}"/>`);

    for (let y = 0; y < GRID_SIZE; y++) {
        let x = 0;
        while (x < GRID_SIZE) {
            if (isPixelOn(imageData, x, y)) {
                const runStart = x;
                x++;
                while (x < GRID_SIZE && isPixelOn(imageData, x, y)) {
                    x++;
                }
                const width = x - runStart;
                parts.push(
                    `<rect x="${runStart}" y="${y}" width="${width}" height="1" fill="${PIXEL_COLOR}"/>`
                );
            } else {
                x++;
            }
        }
    }

    parts.push("</svg>");
    return parts.join("");
}

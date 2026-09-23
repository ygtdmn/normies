import { SVG_OUTPUT_SIZE, BG_COLOR, PIXEL_COLOR } from "../config.js";
import { gridSizeFromLength, isPixelOn } from "./bitmap.js";

/**
 * Generate SVG from a monochrome bitmap of any supported grid size.
 * Mirrors NormiesRendererV6._renderSvg:
 * - viewBox="0 0 n n", width/height fixed to SVG_OUTPUT_SIZE
 * - shape-rendering="crispEdges"
 * - Background rect #e3e5e4, one path of horizontal runs in #48494b
 */
export function renderSvg(imageData: Uint8Array): string {
    const n = gridSizeFromLength(imageData.length);
    const parts: string[] = [];

    parts.push(
        `<svg xmlns="http://www.w3.org/2000/svg" width="${SVG_OUTPUT_SIZE}" height="${SVG_OUTPUT_SIZE}" viewBox="0 0 ${n} ${n}" shape-rendering="crispEdges">`
    );
    parts.push(`<rect width="${n}" height="${n}" fill="${BG_COLOR}"/>`);

    const runs: string[] = [];
    for (let y = 0; y < n; y++) {
        let x = 0;
        while (x < n) {
            if (!isPixelOn(imageData, x, y, n)) {
                x++;
                continue;
            }
            const runStart = x;
            x++;
            while (x < n && isPixelOn(imageData, x, y, n)) x++;
            const w = x - runStart;
            runs.push(`M${runStart} ${y}h${w}v1h-${w}z`);
        }
    }
    if (runs.length > 0) parts.push(`<path fill="${PIXEL_COLOR}" d="${runs.join("")}"/>`);

    parts.push("</svg>");
    return parts.join("");
}

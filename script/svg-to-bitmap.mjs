#!/usr/bin/env node
/**
 * Converts a 400x400 monochrome SVG (10x10 rects) to a 200-byte bitmap
 * for use in Normies Solidity contracts.
 *
 * Usage: node script/svg-to-bitmap.mjs <path-to-svg>
 */
import { readFileSync } from "fs";

const svgPath = process.argv[2];
if (!svgPath) {
    console.error("Usage: node script/svg-to-bitmap.mjs <path-to-svg>");
    process.exit(1);
}

const svg = readFileSync(svgPath, "utf-8");

// 40x40 bitmap, 1 bit per pixel, MSB first
const bitmap = new Uint8Array(200);

// Parse all foreground rect elements (skip the background rect which has width="400")
const rectRegex = /<rect\s+x="(\d+)"\s+y="(\d+)"\s+width="10"\s+height="10"/g;
let match;

while ((match = rectRegex.exec(svg)) !== null) {
    const x = parseInt(match[1]) / 10;
    const y = parseInt(match[2]) / 10;

    if (x < 0 || x >= 40 || y < 0 || y >= 40) {
        console.error(`Warning: pixel (${x}, ${y}) out of bounds, skipping`);
        continue;
    }

    const flatIndex = y * 40 + x;
    const byteIndex = flatIndex >> 3;
    const bitPos = 7 - (flatIndex & 7);
    bitmap[byteIndex] |= 1 << bitPos;
}

// Output as Solidity hex literal
const hex = Array.from(bitmap)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

console.log(`\nSolidity hex literal (${bitmap.length} bytes):\n`);
console.log(`hex"${hex}"`);

// Also output as 0x-prefixed for general use
console.log(`\n0x-prefixed:\n`);
console.log(`0x${hex}`);

// Count set pixels
const pixelCount = bitmap.reduce((sum, byte) => sum + byte.toString(2).split("1").length - 1, 0);
console.log(`\nPixels set: ${pixelCount} / 1600`);

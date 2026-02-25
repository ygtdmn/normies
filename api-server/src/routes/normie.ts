import { Hono } from "hono";
import { parseTokenId } from "../lib/validation.js";
import { getTokenData, getImageData, getTraitsHex } from "../services/token-data.js";
import { getCompositedImageData, getTransformData, getCanvasInfo } from "../services/canvas-data.js";
import { imageDataToPixelString } from "../lib/pixels.js";
import { decodeTraits, countPixels } from "../lib/traits.js";
import { renderSvg } from "../lib/svg.js";
import { svgToPng } from "../lib/png.js";
import { buildMetadata } from "../lib/metadata.js";
import { computePixelDiff } from "../lib/diff.js";
import { CANVAS_ENABLED } from "../config.js";

const normie = new Hono();

// ──────────────────────────────────────────────
//  Existing endpoints (now canvas-aware)
// ──────────────────────────────────────────────

normie.get("/:id/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getCompositedImageData(result.tokenId);
    const pixels = imageDataToPixelString(imageData);
    return c.text(pixels);
});

normie.get("/:id/traits/binary", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const traitsHex = await getTraitsHex(result.tokenId);
    return c.text(traitsHex);
});

normie.get("/:id/traits", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const traitsHex = await getTraitsHex(result.tokenId);
    const decoded = decodeTraits(traitsHex);
    return c.json(decoded);
});

normie.get("/:id/image.svg", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getCompositedImageData(result.tokenId);
    const svg = renderSvg(imageData);
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

normie.get("/:id/image.png", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getCompositedImageData(result.tokenId);
    const svg = renderSvg(imageData);
    const png = svgToPng(svg);
    return new Response(png, { status: 200, headers: { "Content-Type": "image/png" } });
});

normie.get("/:id/metadata", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const [{ imageData: originalImageData, traitsHex }, canvasInfo] = await Promise.all([
        getTokenData(result.tokenId),
        CANVAS_ENABLED ? getCanvasInfo(result.tokenId) : Promise.resolve(undefined),
    ]);

    let imageData = originalImageData;
    if (canvasInfo?.customized) {
        imageData = await getCompositedImageData(result.tokenId);
    }

    const originalPixelCount = countPixels(originalImageData);
    const metadata = buildMetadata(
        result.tokenId,
        imageData,
        traitsHex,
        canvasInfo ? { ...canvasInfo, originalPixelCount } : undefined
    );
    return c.json(metadata);
});

// ──────────────────────────────────────────────
//  Original endpoints (always pre-transform)
// ──────────────────────────────────────────────

normie.get("/:id/original/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getImageData(result.tokenId);
    const pixels = imageDataToPixelString(imageData);
    return c.text(pixels);
});

normie.get("/:id/original/image.svg", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getImageData(result.tokenId);
    const svg = renderSvg(imageData);
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

normie.get("/:id/original/image.png", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getImageData(result.tokenId);
    const svg = renderSvg(imageData);
    const png = svgToPng(svg);
    return new Response(png, { status: 200, headers: { "Content-Type": "image/png" } });
});

// ──────────────────────────────────────────────
//  Canvas endpoints
// ──────────────────────────────────────────────

normie.get("/:id/canvas/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const transformData = await getTransformData(result.tokenId);
    const pixels = imageDataToPixelString(transformData);
    return c.text(pixels);
});

normie.get("/:id/canvas/diff", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const [original, transform] = await Promise.all([
        getImageData(result.tokenId),
        getTransformData(result.tokenId),
    ]);
    const diff = computePixelDiff(original, transform);
    return c.json(diff);
});

normie.get("/:id/canvas/info", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const info = await getCanvasInfo(result.tokenId);
    return c.json(info);
});

export { normie };

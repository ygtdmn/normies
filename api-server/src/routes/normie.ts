import { Hono } from "hono";
import { parseTokenId } from "../lib/validation.js";
import { getTokenData, getImageData, getTraitsHex } from "../services/token-data.js";
import { getTransformData, getCanvasInfo } from "../services/canvas-data.js";
import { imageDataToPixelString } from "../lib/pixels.js";
import { decodeTraits, countPixels } from "../lib/traits.js";
import { renderSvg } from "../lib/svg.js";
import { svgToPng } from "../lib/png.js";
import { buildMetadata, buildMetadataFromAttributes } from "../lib/metadata.js";
import { computePixelDiff } from "../lib/diff.js";
import { getTokenOwner } from "../services/ponder-data.js";
import {
    getActiveBaseImageData,
    getActiveImageData,
    getZombieAttributes,
    getZombieBitmap,
    getZombieConversionsForToken,
    getZombieInfo,
} from "../services/zombie-data.js";
import { getLegendaryCanvasInfo } from "../services/legendary-canvas-data.js";

const normie = new Hono();

// ──────────────────────────────────────────────
//  Ownership (Ponder indexer-backed)
// ──────────────────────────────────────────────

normie.get("/:id/owner", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const data = await getTokenOwner(result.tokenId);
    return c.json(data);
});

// ──────────────────────────────────────────────
//  Existing endpoints (now canvas-aware)
// ──────────────────────────────────────────────

normie.get("/:id/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getActiveImageData(result.tokenId);
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

    const imageData = await getActiveImageData(result.tokenId);
    const svg = renderSvg(imageData);
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

normie.get("/:id/image.png", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getActiveImageData(result.tokenId);
    const svg = renderSvg(imageData);
    const png = svgToPng(svg);
    return new Response(png, { status: 200, headers: { "Content-Type": "image/png" } });
});

normie.get("/:id/metadata", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const [imageData, zombieInfo, canvasInfo, legendaryCanvasInfo] = await Promise.all([
        getActiveImageData(result.tokenId),
        getZombieInfo(result.tokenId),
        getCanvasInfo(result.tokenId),
        getLegendaryCanvasInfo(result.tokenId),
    ]);
    const metadataCanvasInfo = {
        ...canvasInfo,
        legendaryCanvasArtist: legendaryCanvasInfo.artistName,
    };

    if (zombieInfo.isZombie) {
        const attributes = await getZombieAttributes(result.tokenId);
        const metadata = buildMetadataFromAttributes(
            result.tokenId,
            imageData,
            attributes,
            metadataCanvasInfo,
            countPixels(imageData)
        );
        return c.json(metadata);
    }

    const { imageData: originalImageData, traitsHex } = await getTokenData(result.tokenId);
    const originalPixelCount = countPixels(originalImageData);
    const metadata = buildMetadata(
        result.tokenId,
        imageData,
        traitsHex,
        { ...metadataCanvasInfo, originalPixelCount }
    );
    return c.json(metadata);
});

normie.get("/:id/legendary-canvas", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    return c.json(await getLegendaryCanvasInfo(result.tokenId));
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
//  Zombie endpoints (token-scoped aliases)
// ──────────────────────────────────────────────

normie.get("/:id/zombie", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    return c.json({
        info: await getZombieInfo(result.tokenId),
        conversions: await getZombieConversionsForToken(result.tokenId),
    });
});

normie.get("/:id/zombie/attributes", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    return c.json({ attributes: await getZombieAttributes(result.tokenId) });
});

normie.get("/:id/zombie/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const pixels = imageDataToPixelString(await getZombieBitmap(result.tokenId));
    return c.text(pixels);
});

normie.get("/:id/zombie/image.svg", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const svg = renderSvg(await getZombieBitmap(result.tokenId));
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

normie.get("/:id/zombie/image.png", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const svg = renderSvg(await getZombieBitmap(result.tokenId));
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

    const [base, transform] = await Promise.all([
        getActiveBaseImageData(result.tokenId),
        getTransformData(result.tokenId),
    ]);
    const diff = computePixelDiff(base, transform);
    return c.json(diff);
});

normie.get("/:id/canvas/info", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const info = await getCanvasInfo(result.tokenId);
    return c.json(info);
});

export { normie };

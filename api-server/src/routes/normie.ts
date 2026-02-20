import { Hono } from "hono";
import { parseTokenId } from "../lib/validation.js";
import { getTokenData, getImageData, getTraitsHex } from "../services/token-data.js";
import { imageDataToPixelString } from "../lib/pixels.js";
import { decodeTraits } from "../lib/traits.js";
import { renderSvg } from "../lib/svg.js";
import { svgToPng } from "../lib/png.js";
import { buildMetadata } from "../lib/metadata.js";

const normie = new Hono();

normie.get("/:id/pixels", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getImageData(result.tokenId);
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

    const imageData = await getImageData(result.tokenId);
    const svg = renderSvg(imageData);
    return c.body(svg, 200, { "Content-Type": "image/svg+xml" });
});

normie.get("/:id/image.png", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const imageData = await getImageData(result.tokenId);
    const svg = renderSvg(imageData);
    const png = svgToPng(svg);
    return new Response(png, { status: 200, headers: { "Content-Type": "image/png" } });
});

normie.get("/:id/metadata", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const { imageData, traitsHex } = await getTokenData(result.tokenId);
    const metadata = buildMetadata(result.tokenId, imageData, traitsHex);
    return c.json(metadata);
});

export { normie };

import { Hono } from "hono";
import { agentsPrisma } from "../lib/agents-db.js";
import { parseTokenId } from "../lib/validation.js";
import {
    getCanvasInfo,
    getCompositedImageData,
    getTransformData,
} from "../services/canvas-data.js";
import { getImageData } from "../services/token-data.js";
import { computePixelDiff } from "../lib/diff.js";
import { renderSvg } from "../lib/svg.js";

const agents = new Hono();

const METADATA_TYPE_URL =
    "https://eips.ethereum.org/EIPS/eip-8004#registration-v1";

function publicBase(): string {
    const env = process.env.PUBLIC_API_BASE || "https://api.normies.art";
    return env.replace(/\/$/, "");
}

function buildAgentDescription(row: { tagline: string; backstory: string }): string {
    const description = `${row.tagline}. ${row.backstory}`.replace(/\s+/g, " ").trim();
    return description.length <= 500 ? description : description.slice(0, 497) + "…";
}

// ──────────────────────────────────────────────────────────────────────
// /metadata/:tokenId — ERC-8004 metadata JSON served as the on-chain
// agentURI. Reachable for both pending and registered rows so 8004 indexers
// can resolve the URL the moment the on-chain register tx confirms.
// ──────────────────────────────────────────────────────────────────────
agents.get("/metadata/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const row = await agentsPrisma.agent.findUnique({
        where: { tokenId: BigInt(result.tokenId) },
    });
    if (!row) return c.json({ error: "Agent not found" }, 404);

    const base = publicBase();
    const updatedAt = Math.floor(row.updatedAt.getTime() / 1000);

    c.header("Cache-Control", "public, max-age=60, s-maxage=120, stale-while-revalidate=300");
    c.header("Access-Control-Allow-Origin", "*");
    return c.json({
        type: METADATA_TYPE_URL,
        name: row.name.slice(0, 200),
        description: buildAgentDescription(row),
        image: `${base}/agents/image/${row.tokenId.toString()}`,
        services: [
            {
                name: "web",
                endpoint: `${base}/agents/info/${row.tokenId.toString()}`,
                version: "1",
            },
        ],
        supportedTrust: ["reputation"],
        active: row.status === "registered",
        x402Support: false,
        updatedAt,
    });
});

// ──────────────────────────────────────────────────────────────────────
// /info/:tokenId — rich persona JSON for explorers + UIs. Persona snapshot
// from DB merged with live on-chain canvas state. 404s for pending rows.
// ──────────────────────────────────────────────────────────────────────
agents.get("/info/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const row = await agentsPrisma.agent.findUnique({
        where: { tokenId: BigInt(result.tokenId) },
    });
    if (!row || row.status !== "registered") {
        return c.json({ error: "Agent not found" }, 404);
    }

    const canvasInfo = await getCanvasInfo(result.tokenId);
    let diff: { addedCount: number; removedCount: number; netChange: number } | null = null;
    if (canvasInfo.customized) {
        try {
            const [original, transform] = await Promise.all([
                getImageData(result.tokenId),
                getTransformData(result.tokenId),
            ]);
            diff = computePixelDiff(original, transform);
        } catch {
            // diff stays null; level + actionPoints are still authoritative
        }
    }

    c.header("Cache-Control", "public, max-age=30, s-maxage=60, stale-while-revalidate=300");
    c.header("Access-Control-Allow-Origin", "*");
    return c.json({
        tokenId: row.tokenId.toString(),
        agentId: row.agentId?.toString() ?? null,
        chainId: row.chainId,
        name: row.name,
        type: row.type,
        tagline: row.tagline,
        backstory: row.backstory,
        greeting: row.greeting,
        personalityTraits: row.personalityTraits,
        communicationStyle: row.communicationStyle,
        quirks: row.quirks,
        systemPrompt: row.systemPrompt,
        traits: row.traits,
        canvas: {
            level: canvasInfo.level,
            actionPoints: canvasInfo.actionPoints,
            customized: canvasInfo.customized,
            diff,
        },
        registeredBy: row.registeredBy,
        registeredAt: row.createdAt.toISOString(),
        txHash: row.txHash,
        interactions: { status: "coming_soon" },
        mcp: { status: "coming_soon" },
    });
});

agents.get("/image/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    try {
        const imageData = await getCompositedImageData(result.tokenId);
        const svg = renderSvg(imageData);
        return c.body(svg, 200, {
            "Content-Type": "image/svg+xml",
            "Cache-Control": "public, max-age=60, s-maxage=60, stale-while-revalidate=300",
            "Access-Control-Allow-Origin": "*",
        });
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Failed to render Normie SVG" },
            502,
        );
    }
});

export { agents };

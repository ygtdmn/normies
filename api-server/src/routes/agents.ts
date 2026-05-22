import { Hono } from "hono";
import { parseTokenId } from "../lib/validation.js";
import {
    getCanvasInfo,
    getCompositedImageData,
    getTransformData,
} from "../services/canvas-data.js";
import { getDecodedTraits, getImageData } from "../services/token-data.js";
import { computePixelDiff } from "../lib/diff.js";
import { renderSvg } from "../lib/svg.js";
import {
    countAgentBindings,
    getAgentBinding,
    getAgentBindingByAgentId,
    getAgentBindings,
    getAllAgentBindings,
} from "../services/ponder-data.js";
import { buildLivePersona, buildAgentIdentity } from "../services/persona-live.js";
import { searchByName, type AgentIndexEntry } from "../services/agent-search-index.js";
import { personaToDescription } from "../lib/persona.js";
import { agentResponseCache } from "../services/cache.js";
import { CHAIN_ID, NORMIES_ADDRESS } from "../config.js";

// Mint-time immutable traits exposed in the /info response. Mutable canvas-
// derived state lives under the `canvas` field instead.
const STATIC_TRAITS = new Set([
    "Type",
    "Gender",
    "Age",
    "Hair Style",
    "Facial Feature",
    "Expression",
    "Eyes",
    "Accessory",
]);

function staticAttributes(all: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    for (const k of Object.keys(all)) {
        if (STATIC_TRAITS.has(k)) out[k] = all[k];
    }
    return out;
}

interface AgentRow {
    tokenId: bigint;
    agentId: bigint;
    chainId: number;
    txHash: string;
    registeredBy: string;
    registeredAt: Date;
}

/**
 * Memoize a route handler's JSON body per (route, tokenId) so repeated hits
 * within the response-cache TTL skip persona generation entirely. The 404
 * sentinel keeps non-existent agents from hammering loadAgentRow.
 */
async function cachedAgentResponse<T>(
    routeKey: string,
    tokenId: number | string,
    build: () => Promise<{ body: T; status?: number } | null>,
): Promise<{ body: T | { error: string }; status: number }> {
    const cacheKey = `${routeKey}:${tokenId}`;
    const cached = agentResponseCache.get(cacheKey) as { body: T | { error: string }; status: number } | undefined;
    if (cached) return cached;
    const result = await build();
    const out = result
        ? { body: result.body, status: result.status ?? 200 }
        : { body: { error: "Agent not found" }, status: 404 };
    agentResponseCache.set(cacheKey, out);
    return out;
}

/**
 * Resolve a Normie's agent identity from the indexer's AgentBound view. Returns
 * null only if the token has not been registered.
 */
async function loadAgentRow(tokenId: bigint): Promise<AgentRow | null> {
    const binding = await getAgentBinding(NORMIES_ADDRESS, tokenId);
    if (!binding) return null;
    return {
        tokenId,
        agentId: BigInt(binding.agentId),
        chainId: CHAIN_ID,
        txHash: binding.txHash,
        registeredBy: binding.registeredBy,
        registeredAt: new Date(Number(binding.timestamp) * 1000),
    };
}

const agents = new Hono();

const METADATA_TYPE_URL =
    "https://eips.ethereum.org/EIPS/eip-8004#registration-v1";

/**
 * Version of the A2A (Agent2Agent) Agent Card spec we serve. ERC-8004
 * service entries advertise this in `version`, and consumers like 8004scan
 * use it to negotiate the right parser.
 */
const A2A_VERSION = "0.3.0";

function publicBase(): string {
    const env = process.env.PUBLIC_API_BASE || "https://api.normies.art";
    return env.replace(/\/$/, "");
}

function fullAgentName(tokenId: bigint | number | string, name: string): string {
    return `Normie #${tokenId.toString()} - ${name}`.slice(0, 200);
}

function agentCardUrl(tokenId: bigint | string | number): string {
    return `${publicBase()}/agents/agent-card/${tokenId.toString()}`;
}

// ──────────────────────────────────────────────────────────────────────
// /metadata/:tokenId — ERC-8004 metadata JSON served as the on-chain
// agentURI. Reachable for both pending and registered rows so 8004 indexers
// can resolve the URL the moment the on-chain register tx confirms.
// ──────────────────────────────────────────────────────────────────────
agents.get("/metadata/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const { body, status } = await cachedAgentResponse("metadata", result.tokenId, async () => {
        const row = await loadAgentRow(BigInt(result.tokenId));
        if (!row) return null;
        const persona = await buildLivePersona(result.tokenId);
        const base = publicBase();
        const updatedAt = Math.floor(row.registeredAt.getTime() / 1000);
        return {
            body: {
                type: METADATA_TYPE_URL,
                name: fullAgentName(row.tokenId, persona.name),
                description: personaToDescription(persona),
                image: `${base}/agents/image/${row.tokenId.toString()}`,
                services: [
                    {
                        name: "web",
                        endpoint: `${base}/agents/info/${row.tokenId.toString()}`,
                        version: "1",
                    },
                    {
                        name: "A2A",
                        endpoint: agentCardUrl(row.tokenId),
                        version: A2A_VERSION,
                    },
                ],
                active: true,
                x402Support: false,
                updatedAt,
            },
        };
    });

    c.header("Cache-Control", "public, max-age=60, s-maxage=120, stale-while-revalidate=300");
    c.header("Access-Control-Allow-Origin", "*");
    return c.json(body, status as 200 | 404);
});

// ──────────────────────────────────────────────────────────────────────
// /persona-preview/:tokenId — public, returns the full Persona JSON for
// any tokenId regardless of registration status. Used by the lab during
// the awakening flow so the reveal sequence and DB-write share one source
// of persona text.
// ──────────────────────────────────────────────────────────────────────
agents.get("/persona-preview/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    try {
        const persona = await buildLivePersona(result.tokenId);
        c.header("Cache-Control", "public, max-age=30, s-maxage=60, stale-while-revalidate=300");
        c.header("Access-Control-Allow-Origin", "*");
        return c.json(persona);
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Failed to build persona" },
            502,
        );
    }
});

// ──────────────────────────────────────────────────────────────────────
// /identity/:tokenId — name + type + raw trait map. Pure trait-derived,
// no canvas reads, longer cache window. Used by the gallery list and the
// bindings endpoint where the full persona is overkill.
// ──────────────────────────────────────────────────────────────────────
agents.get("/identity/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    try {
        const identity = await buildAgentIdentity(result.tokenId);
        c.header("Cache-Control", "public, max-age=300, s-maxage=600, stale-while-revalidate=3600");
        c.header("Access-Control-Allow-Origin", "*");
        return c.json(identity);
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Failed to read agent identity" },
            502,
        );
    }
});

/**
 * Build the /info JSON body for a registered agent. Shared between
 * /info/:tokenId and /by-agent-id/:agentId/info so both surfaces speak the
 * same shape and stay in lockstep when fields evolve.
 */
async function buildAgentInfoBody(row: AgentRow, tokenId: number) {
    const [persona, canvasInfo, attributes] = await Promise.all([
        buildLivePersona(tokenId),
        getCanvasInfo(tokenId),
        getDecodedTraits(tokenId),
    ]);
    let diff: { addedCount: number; removedCount: number; netChange: number } | null = null;
    if (canvasInfo.customized) {
        try {
            const [original, transform] = await Promise.all([
                getImageData(tokenId),
                getTransformData(tokenId),
            ]);
            diff = computePixelDiff(original, transform);
        } catch {
            // diff stays null; level + actionPoints are still authoritative
        }
    }
    return {
        tokenId: row.tokenId.toString(),
        agentId: row.agentId.toString(),
        chainId: row.chainId,
        name: persona.name,
        type: persona.type,
        tagline: persona.tagline,
        backstory: persona.backstory,
        greeting: persona.greeting,
        personalityTraits: persona.personalityTraits,
        communicationStyle: persona.communicationStyle,
        quirks: persona.quirks,
        systemPrompt: persona.systemPrompt,
        traits: {
            name: `Normie #${row.tokenId.toString()}`,
            attributes: staticAttributes(attributes),
        },
        canvas: {
            level: canvasInfo.level,
            actionPoints: canvasInfo.actionPoints,
            customized: canvasInfo.customized,
            diff,
        },
        registeredBy: row.registeredBy,
        registeredAt: row.registeredAt.toISOString(),
        txHash: row.txHash,
        interactions: { status: "coming_soon" },
        mcp: { status: "coming_soon" },
    };
}

// ──────────────────────────────────────────────────────────────────────
// /info/:tokenId — rich persona JSON for explorers + UIs. Persona snapshot
// from DB merged with live on-chain canvas state. 404s for pending rows.
// ──────────────────────────────────────────────────────────────────────
agents.get("/info/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const { body, status } = await cachedAgentResponse("info", result.tokenId, async () => {
        const row = await loadAgentRow(BigInt(result.tokenId));
        if (!row) return null;
        return { body: await buildAgentInfoBody(row, result.tokenId) };
    });

    c.header("Cache-Control", "public, max-age=30, s-maxage=60, stale-while-revalidate=300");
    c.header("Access-Control-Allow-Origin", "*");
    return c.json(body, status as 200 | 404);
});

// ──────────────────────────────────────────────────────────────────────
// /by-agent-id/:agentId/info — reverse lookup. Resolves agentId → tokenId
// via the Ponder indexer, then returns the same payload as /info/:tokenId.
// Lets the lab's agent detail page do a single round trip instead of two.
// ──────────────────────────────────────────────────────────────────────
agents.get("/by-agent-id/:agentId/info", async (c) => {
    let agentId: bigint;
    try {
        agentId = BigInt(c.req.param("agentId"));
    } catch {
        return c.json({ error: "Invalid agentId" }, 400);
    }

    let binding;
    try {
        binding = await getAgentBindingByAgentId(agentId);
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Indexer lookup failed" },
            502,
        );
    }
    if (!binding) return c.json({ error: "Agent not found" }, 404);

    const tokenId = BigInt(binding.tokenId);
    const row = await loadAgentRow(tokenId);
    if (!row) {
        return c.json({ error: "Agent not found" }, 404);
    }

    const body = await buildAgentInfoBody(row, Number(tokenId));
    c.header("Cache-Control", "public, max-age=30, s-maxage=60, stale-while-revalidate=300");
    c.header("Access-Control-Allow-Origin", "*");
    return c.json(body);
});

// ──────────────────────────────────────────────────────────────────────
// /list — paginated gallery feed, enriched with identity (name + type).
// Source of pagination is Ponder's agent_binding table (authoritative for
// "is this registered on-chain?"); identity is built per row from cached
// on-chain trait reads. Lab gallery uses this for both server-rendered
// first page and client-side infinite scroll.
//
//   GET /agents/list?sort=newest|oldest&limit=N&cursor=<agentId>
// ──────────────────────────────────────────────────────────────────────
agents.get("/list", async (c) => {
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 24), 1), 100);
    const sortParam = c.req.query("sort");
    const sort = sortParam === "oldest" ? "asc" : "desc";
    const cursorRaw = c.req.query("cursor");
    let cursor: bigint | undefined;
    if (cursorRaw) {
        try {
            cursor = BigInt(cursorRaw);
        } catch {
            return c.json({ error: "`cursor` must be an integer string" }, 400);
        }
    }

    let res;
    try {
        res = await getAllAgentBindings({
            tokenContract: NORMIES_ADDRESS,
            limit,
            cursor,
            sort,
        });
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Indexer lookup failed" },
            502,
        );
    }

    // Resolve identity per row in parallel — buildAgentIdentity is cheap
    // after the first hit since decoded traits are process-cached.
    const identities = await Promise.all(
        res.bindings.map((b) =>
            buildAgentIdentity(Number(b.tokenId)).catch(() => null),
        ),
    );

    const items = res.bindings.map((b, i) => {
        const id = identities[i];
        return {
            agentId: b.agentId,
            tokenId: b.tokenId,
            name: id?.name ?? `Normie #${b.tokenId}`,
            type: id?.type ?? "",
            registeredBy: b.registeredBy,
            registeredAt: b.timestamp,
            txHash: b.txHash,
        };
    });

    c.header("Cache-Control", "public, max-age=30, s-maxage=60, stale-while-revalidate=300");
    c.header("Access-Control-Allow-Origin", "*");
    return c.json({ items, hasMore: res.hasMore });
});

// ──────────────────────────────────────────────────────────────────────
// /search — gallery search across all registered agents.
//
//   GET /agents/search?q=<query>&limit=N
//
// Numeric queries resolve as exact matches against agentId and/or tokenId
// (cheap binding lookups, no index build). Non-numeric queries fall back
// to a substring filter over a lazily-built name index — the first call
// after the TTL pays for an enrich sweep; subsequent calls are in-memory.
// ──────────────────────────────────────────────────────────────────────
agents.get("/search", async (c) => {
    const qRaw = c.req.query("q") ?? "";
    const q = qRaw.trim();
    const limit = Math.min(Math.max(Number(c.req.query("limit") ?? 24), 1), 50);
    if (!q) return c.json({ items: [], hasMore: false });

    c.header("Access-Control-Allow-Origin", "*");
    c.header("Cache-Control", "public, max-age=15, s-maxage=30, stale-while-revalidate=120");

    const toItem = async (b: { agentId: string; tokenId: string; registeredBy: string; timestamp: string; txHash: string }) => {
        const id = await buildAgentIdentity(Number(b.tokenId)).catch(() => null);
        return {
            agentId: b.agentId,
            tokenId: b.tokenId,
            name: id?.name ?? `Normie #${b.tokenId}`,
            type: id?.type ?? "",
            registeredBy: b.registeredBy,
            registeredAt: b.timestamp,
            txHash: b.txHash,
        };
    };

    if (/^\d+$/.test(q)) {
        try {
            const [byToken, byAgent] = await Promise.all([
                getAgentBinding(NORMIES_ADDRESS, q).catch(() => null),
                getAgentBindingByAgentId(q).catch(() => null),
            ]);

            const items: AgentIndexEntry[] = [];
            const seen = new Set<string>();
            for (const b of [byAgent, byToken]) {
                if (!b) continue;
                if (b.tokenContract.toLowerCase() !== NORMIES_ADDRESS.toLowerCase()) continue;
                if (seen.has(b.agentId)) continue;
                seen.add(b.agentId);
                items.push(await toItem(b));
            }
            return c.json({ items, hasMore: false });
        } catch (err) {
            return c.json(
                { error: err instanceof Error ? err.message : "Search failed" },
                502,
            );
        }
    }

    try {
        const items = await searchByName(q, limit);
        return c.json({ items, hasMore: items.length >= limit });
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Search failed" },
            502,
        );
    }
});

// ──────────────────────────────────────────────────────────────────────
// /count — total registered Normies agents, used by the gallery header.
// ──────────────────────────────────────────────────────────────────────
agents.get("/count", async (c) => {
    try {
        const total = await countAgentBindings({ tokenContract: NORMIES_ADDRESS });
        c.header("Cache-Control", "public, max-age=30, s-maxage=60, stale-while-revalidate=300");
        c.header("Access-Control-Allow-Origin", "*");
        return c.json({ count: total });
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Indexer lookup failed" },
            502,
        );
    }
});

// ──────────────────────────────────────────────────────────────────────
// /agent-card/:tokenId — A2A (Agent2Agent) v0.3.x Agent Card JSON.
// Linked from /metadata/:tokenId's `services` array so any 8004 indexer
// can discover the A2A surface for this agent. The agent's persona snapshot
// drives `name`, `description`, `iconUrl`, and a single conversational
// `skill`. The protocol-binding URL points at our (forthcoming) A2A
// endpoint — the surface advertises but is not yet implemented.
// ──────────────────────────────────────────────────────────────────────
agents.get("/agent-card/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    const { body, status } = await cachedAgentResponse("agent-card", result.tokenId, async () => {
        const row = await loadAgentRow(BigInt(result.tokenId));
        if (!row) return null;
        const persona = await buildLivePersona(result.tokenId);
        const base = publicBase();
        const tokenIdStr = row.tokenId.toString();
        const lowerType = persona.type.toLowerCase();
        return {
            body: {
                name: persona.name,
                description: personaToDescription(persona),
                supportedInterfaces: [
                    {
                        url: `${base}/agents/a2a/${tokenIdStr}`,
                        protocolBinding: "HTTP+JSON",
                        protocolVersion: "1.0",
                    },
                ],
                provider: {
                    organization: "Normies",
                    url: "https://normies.art",
                },
                iconUrl: `${base}/agents/image/${tokenIdStr}`,
                version: "1.0.0",
                documentationUrl: `${base}/docs`,
                capabilities: {
                    streaming: false,
                    pushNotifications: false,
                    stateTransitionHistory: false,
                    extendedAgentCard: false,
                },
                securitySchemes: {},
                security: [],
                defaultInputModes: ["text/plain"],
                defaultOutputModes: ["text/plain"],
                skills: [
                    {
                        id: "converse",
                        name: `Converse with ${persona.name}`,
                        description: persona.tagline,
                        tags: [lowerType, "conversation", "erc-8004"],
                        examples: [persona.greeting],
                        inputModes: ["text/plain"],
                        outputModes: ["text/plain"],
                    },
                ],
            },
        };
    });

    c.header("Cache-Control", "public, max-age=60, s-maxage=120, stale-while-revalidate=300");
    c.header("Access-Control-Allow-Origin", "*");
    return c.json(body, status as 200 | 404);
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

// ──────────────────────────────────────────────────────────────────────
// Agent-binding lookups, backed by the required Ponder indexer (not public).
// These let downstream apps (incl. the lab) avoid direct on-chain
// eth_getLogs / agentIdForBinding calls.
// ──────────────────────────────────────────────────────────────────────

// GET /agents/binding/:tokenId — Normies-only single-token lookup.
agents.get("/binding/:tokenId", async (c) => {
    const result = parseTokenId(c.req.param("tokenId"));
    if ("error" in result) return c.json({ error: result.error }, 400);

    try {
        const binding = await getAgentBinding(NORMIES_ADDRESS, result.tokenId);
        c.header("Cache-Control", "public, max-age=30, s-maxage=60, stale-while-revalidate=300");
        c.header("Access-Control-Allow-Origin", "*");
        return c.json({ binding });
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Indexer lookup failed" },
            502,
        );
    }
});

// POST /agents/binding/batch — Normies-only batch lookup.
//   body: { tokenIds: (string|number)[] }
//   returns: { bindings: { [tokenId]: AgentBinding } }
agents.post("/binding/batch", async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as {
        tokenIds?: (string | number)[];
    };
    if (!Array.isArray(body.tokenIds) || body.tokenIds.length === 0) {
        return c.json({ bindings: {} });
    }

    try {
        const bindings = await getAgentBindings(NORMIES_ADDRESS, body.tokenIds);
        c.header("Cache-Control", "public, max-age=30, s-maxage=60");
        c.header("Access-Control-Allow-Origin", "*");
        return c.json({ bindings });
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Indexer batch lookup failed" },
            502,
        );
    }
});

// GET /agents/by-agent-id/:agentId — reverse lookup (agentId → token).
agents.get("/by-agent-id/:agentId", async (c) => {
    let agentId: bigint;
    try {
        agentId = BigInt(c.req.param("agentId"));
    } catch {
        return c.json({ error: "Invalid agentId" }, 400);
    }

    try {
        const binding = await getAgentBindingByAgentId(agentId);
        c.header("Cache-Control", "public, max-age=60, s-maxage=300");
        c.header("Access-Control-Allow-Origin", "*");
        return c.json({ binding });
    } catch (err) {
        return c.json(
            { error: err instanceof Error ? err.message : "Indexer lookup failed" },
            502,
        );
    }
});

export { agents };

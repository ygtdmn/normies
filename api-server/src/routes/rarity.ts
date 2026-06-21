import { Hono } from "hono";
import { parseTokenId } from "../lib/validation.js";
import { getRarityLegendaryConfig, putRarityLegendaryConfig } from "../services/ponder-data.js";
import {
    getHistoricalRarityHolder,
    getHistoricalRarityNormie,
    getHistoricalRarityStats,
    getHistoricalRarityTraits,
    getHistoricalRecursiveBurnHolders,
    getRarityHolder,
    getRarityNormie,
    getRarityPersona,
    getRarityStats,
    getRarityTraits,
    getRecursiveBurnHolders,
    listHistoricalRarityNormies,
    listRarityNormies,
    refreshRarityNormie,
} from "../services/rarity-data.js";
import { subscribeListingEvents } from "../services/rarity-listings.js";

const TOTAL_SUPPLY = 10_000;
const ADMIN_KEY = process.env.ADMIN_KEY || process.env.RARITY_ADMIN_KEY || "";

type LegendaryStore = {
    current: Array<{ id: number; artist: string }>;
    upcoming: Array<{ id: number; artist: string }>;
};

const rarity = new Hono();

rarity.get("/docs", (c) => c.json({
    base: "/rarity",
    endpoints: [
        "GET /stats",
        "GET /normies",
        "GET /normie/:id",
        "POST /normie/:id/refresh",
        "GET /normie/:id/persona",
        "GET /traits",
        "GET /holder/:address",
        "GET /recursive-burn-holders",
        "GET /historical/:blockNumber/stats",
        "GET /historical/:blockNumber/normies",
        "GET /historical/:blockNumber/normie/:id",
        "GET /historical/:blockNumber/traits",
        "GET /historical/:blockNumber/holder/:address",
        "GET /historical/:blockNumber/recursive-burn-holders",
        "GET /legendary",
        "PUT /admin/legendary",
        "SSE /listings/stream",
    ],
}));

rarity.get("/normies", async (c) => {
    return c.json(await listRarityNormies(new URL(c.req.url).searchParams));
});

rarity.get("/historical/:blockNumber/normies", async (c) => {
    const blockNumber = parseBlockNumber(c.req.param("blockNumber"));
    if ("error" in blockNumber) return c.json({ error: blockNumber.error }, 400);
    return c.json(await listHistoricalRarityNormies(blockNumber.value, new URL(c.req.url).searchParams));
});

rarity.get("/normie/:id", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const out = await getRarityNormie(result.tokenId);
    return c.json(out.body, out.status);
});

rarity.get("/historical/:blockNumber/normie/:id", async (c) => {
    const blockNumber = parseBlockNumber(c.req.param("blockNumber"));
    if ("error" in blockNumber) return c.json({ error: blockNumber.error }, 400);
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const out = await getHistoricalRarityNormie(blockNumber.value, result.tokenId);
    return c.json(out.body, out.status);
});

rarity.post("/normie/:id/refresh", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const out = await refreshRarityNormie(result.tokenId);
    return c.json(out.body, out.status);
});

rarity.get("/normie/:id/persona", async (c) => {
    const result = parseTokenId(c.req.param("id"));
    if ("error" in result) return c.json({ error: result.error }, 400);
    const out = await getRarityPersona(result.tokenId);
    return c.json(out.body, out.status);
});

rarity.get("/traits", async (c) => c.json(await getRarityTraits()));

rarity.get("/historical/:blockNumber/traits", async (c) => {
    const blockNumber = parseBlockNumber(c.req.param("blockNumber"));
    if ("error" in blockNumber) return c.json({ error: blockNumber.error }, 400);
    return c.json(await getHistoricalRarityTraits(blockNumber.value));
});

rarity.get("/stats", async (c) => c.json(await getRarityStats()));

rarity.get("/historical/:blockNumber/stats", async (c) => {
    const blockNumber = parseBlockNumber(c.req.param("blockNumber"));
    if ("error" in blockNumber) return c.json({ error: blockNumber.error }, 400);
    return c.json(await getHistoricalRarityStats(blockNumber.value));
});

rarity.get("/holder/:address", async (c) => {
    const raw = c.req.param("address").trim();
    if (!raw) return c.json({ error: "Address required" }, 400);

    const resolved = await resolveHolder(raw);
    if ("error" in resolved) return c.json({ error: resolved.error }, resolved.status);

    const body = await getRarityHolder(resolved.address);
    return c.json({ ...body, ens: resolved.ens });
});

rarity.get("/historical/:blockNumber/holder/:address", async (c) => {
    const blockNumber = parseBlockNumber(c.req.param("blockNumber"));
    if ("error" in blockNumber) return c.json({ error: blockNumber.error }, 400);

    const raw = c.req.param("address").trim();
    if (!raw) return c.json({ error: "Address required" }, 400);

    const resolved = await resolveHolder(raw);
    if ("error" in resolved) return c.json({ error: resolved.error }, resolved.status);

    const body = await getHistoricalRarityHolder(blockNumber.value, resolved.address);
    return c.json({ ...body, ens: resolved.ens });
});

rarity.get("/recursive-burn-holders", async (c) => {
    const limit = Math.min(200, Math.max(1, Number(c.req.query("limit") ?? 50) || 50));
    const wallet = c.req.query("wallet")?.trim();
    return c.json(await getRecursiveBurnHolders(limit, wallet));
});

rarity.get("/historical/:blockNumber/recursive-burn-holders", async (c) => {
    const blockNumber = parseBlockNumber(c.req.param("blockNumber"));
    if ("error" in blockNumber) return c.json({ error: blockNumber.error }, 400);
    const limit = Math.min(200, Math.max(1, Number(c.req.query("limit") ?? 50) || 50));
    const wallet = c.req.query("wallet")?.trim();
    return c.json(await getHistoricalRecursiveBurnHolders(blockNumber.value, limit, wallet));
});

rarity.get("/listings/stream", (c) => {
    const encoder = new TextEncoder();
    const stream = new TransformStream<Uint8Array>();
    const writer = stream.writable.getWriter();

    void writer.write(encoder.encode(":ok\n\n"));
    const unsubscribe = subscribeListingEvents((event) => {
        void writer.write(encoder.encode(`data: ${JSON.stringify(event)}\n\n`)).catch(() => unsubscribe());
    });

    c.req.raw.signal.addEventListener("abort", () => {
        unsubscribe();
        void writer.close().catch(() => undefined);
    }, { once: true });

    return new Response(stream.readable, {
        status: 200,
        headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            Connection: "keep-alive",
            "Access-Control-Allow-Origin": "*",
        },
    });
});

rarity.get("/legendary", async (c) => c.json(await getRarityLegendaryConfig()));

rarity.put("/admin/legendary", async (c) => {
    if (!ADMIN_KEY) return c.json({ error: "Admin disabled" }, 403);
    if (c.req.header("x-admin-key") !== ADMIN_KEY) return c.json({ error: "Invalid admin key" }, 401);

    const body = await c.req.json().catch(() => null) as Partial<LegendaryStore> | null;
    if (!body || !Array.isArray(body.current) || !Array.isArray(body.upcoming)) {
        return c.json({ error: "Body must include current[] and upcoming[] arrays" }, 400);
    }

    const legendaryStore = normalizeLegendary(body);
    return c.json(await putRarityLegendaryConfig({
        ...legendaryStore,
        updatedBy: "api-server",
    }));
});

function parseBlockNumber(raw: string): { value: bigint } | { error: string } {
    if (!/^\d+$/.test(raw)) return { error: "Invalid blockNumber" };
    const value = BigInt(raw);
    if (value < 0n) return { error: "Invalid blockNumber" };
    return { value };
}

async function resolveHolder(raw: string): Promise<{ address: string; ens: string | null } | { error: string; status: 400 | 404 }> {
    if (raw.endsWith(".eth")) {
        const res = await fetch(`https://api.ensideas.com/ens/resolve/${encodeURIComponent(raw)}`, {
            signal: AbortSignal.timeout(10_000),
        }).catch(() => null);
        if (!res?.ok) return { error: "ENS resolution failed", status: 404 };
        const data = await res.json().catch(() => null) as { address?: string } | null;
        if (!data?.address) return { error: "ENS name not found", status: 404 };
        return { address: data.address.toLowerCase(), ens: raw };
    }

    if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) {
        return { error: "Invalid Ethereum address", status: 400 };
    }
    return { address: raw.toLowerCase(), ens: null };
}

function normalizeLegendary(data: Partial<LegendaryStore>): LegendaryStore {
    const cleanItem = (item: unknown): { id: number; artist: string } | null => {
        if (!item || typeof item !== "object") return null;
        const record = item as Record<string, unknown>;
        const id = Number.parseInt(String(record.id), 10);
        if (!Number.isInteger(id) || id < 0 || id >= TOTAL_SUPPLY) return null;
        return { id, artist: String(record.artist ?? "").trim().slice(0, 60) };
    };
    const dedupe = (items: Array<{ id: number; artist: string } | null>) => {
        const seen = new Set<number>();
        return items.filter((item): item is { id: number; artist: string } => {
            if (!item || seen.has(item.id)) return false;
            seen.add(item.id);
            return true;
        });
    };

    const current = dedupe((data.current ?? []).map(cleanItem));
    const currentIds = new Set(current.map((item) => item.id));
    const upcoming = dedupe((data.upcoming ?? []).map(cleanItem)).filter((item) => !currentIds.has(item.id));
    return { current, upcoming };
}

export { rarity };

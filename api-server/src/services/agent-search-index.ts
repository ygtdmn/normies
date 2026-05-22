/**
 * Lazy in-memory search index for the agent gallery. Names come from
 * deterministic trait-derived persona generation, so once built per
 * (tokenId, traits) pair the entry is stable for the life of the agent
 * binding. We walk the full binding list on first use, enrich each row
 * with identity (cached), and keep the flat array around for substring
 * filtering. A periodic rebuild picks up newly registered agents.
 */

import { NORMIES_ADDRESS } from "../config.js";
import { getAllAgentBindings, type AgentBindingData } from "./ponder-data.js";
import { buildAgentIdentity } from "./persona-live.js";

export interface AgentIndexEntry {
    agentId: string;
    tokenId: string;
    name: string;
    type: string;
    registeredBy: string;
    registeredAt: string;
    txHash: string;
}

const REBUILD_TTL_MS = 5 * 60 * 1000;
const PAGE_SIZE = 100;
const ENRICH_CONCURRENCY = 16;

let entries: AgentIndexEntry[] | null = null;
let builtAt = 0;
let building: Promise<AgentIndexEntry[]> | null = null;

async function enrich(b: AgentBindingData): Promise<AgentIndexEntry> {
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
}

async function rebuild(): Promise<AgentIndexEntry[]> {
    const all: AgentBindingData[] = [];
    let cursor: bigint | undefined;
    // Walk ascending so the cursor (agentId) is monotonically increasing
    // and we can detect the end via hasMore.
    while (true) {
        const res = await getAllAgentBindings({
            tokenContract: NORMIES_ADDRESS,
            limit: PAGE_SIZE,
            cursor,
            sort: "asc",
        });
        all.push(...res.bindings);
        if (!res.hasMore || res.bindings.length === 0) break;
        cursor = BigInt(res.bindings[res.bindings.length - 1].agentId);
    }

    // Enrich with limited concurrency so we don't fan out 10k parallel trait
    // reads on a cold cache; warm hits return immediately anyway.
    const out: AgentIndexEntry[] = new Array(all.length);
    let next = 0;
    async function worker() {
        while (true) {
            const i = next++;
            if (i >= all.length) return;
            out[i] = await enrich(all[i]);
        }
    }
    await Promise.all(
        Array.from({ length: Math.min(ENRICH_CONCURRENCY, all.length) }, () => worker()),
    );

    entries = out;
    builtAt = Date.now();
    return out;
}

export async function getAgentIndex(): Promise<AgentIndexEntry[]> {
    if (entries && Date.now() - builtAt < REBUILD_TTL_MS) return entries;
    if (!building) {
        building = rebuild().finally(() => {
            building = null;
        });
    }
    return building;
}

/**
 * Search the index by case-insensitive name substring. Numeric exact-match
 * on tokenId / agentId is handled by the route directly (it can hit the
 * binding helpers without paying the full-index build cost).
 */
export async function searchByName(query: string, limit: number): Promise<AgentIndexEntry[]> {
    const needle = query.trim().toLowerCase();
    if (!needle) return [];
    const idx = await getAgentIndex();
    const out: AgentIndexEntry[] = [];
    for (const e of idx) {
        if (e.name.toLowerCase().includes(needle)) {
            out.push(e);
            if (out.length >= limit) break;
        }
    }
    return out;
}

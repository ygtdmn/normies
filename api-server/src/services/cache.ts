import { LRUCache } from "lru-cache";
import { CACHE_MAX_ENTRIES, CACHE_TTL_MS, CANVAS_CACHE_TTL_MS, CANVAS_INFO_CACHE_TTL_MS } from "../config.js";

// Traits are written exactly once at mint and have no on-chain mutator after
// that, so cached values are provably stale-free for the lifetime of the
// process. No TTL; we bump max so the whole 10k-supply fits resident.
const TRAITS_CACHE_MAX = Math.max(CACHE_MAX_ENTRIES, 12_000);

export const imageDataCache = new LRUCache<number, Uint8Array>({
    max: CACHE_MAX_ENTRIES,
    ttl: CACHE_TTL_MS,
});

export const traitsCache = new LRUCache<number, `0x${string}`>({
    max: TRAITS_CACHE_MAX,
});

// Decoded form (Record<traitName, value>) — skips decodeTraits work per
// persona request. Same immutability guarantee as traitsCache.
export const decodedTraitsCache = new LRUCache<number, Record<string, string>>({
    max: TRAITS_CACHE_MAX,
});

export const transformDataCache = new LRUCache<number, Uint8Array>({
    max: CACHE_MAX_ENTRIES,
    ttl: CANVAS_CACHE_TTL_MS,
});

export const isTransformedCache = new LRUCache<number, boolean>({
    max: CACHE_MAX_ENTRIES,
    ttl: CANVAS_CACHE_TTL_MS,
});

export interface CanvasInfo {
    actionPoints: number;
    level: number;
    customized: boolean;
    delegate: string;
    delegateSetBy: string;
}

export const canvasInfoCache = new LRUCache<number, CanvasInfo>({
    max: CACHE_MAX_ENTRIES,
    ttl: CANVAS_INFO_CACHE_TTL_MS,
});

// AgentBound bindings are immutable post-mint of the binding tx — once an
// agentId is assigned to a tokenId, the indexer's row never changes. Keyed by
// `${tokenContract}:${tokenId}` so we can serve multiple collections later.
// Null entries (token not yet bound) get a short TTL so newly registered
// agents start resolving quickly without per-request indexer round-trips.
// Value is wrapped in a single-key object so we can cache the "binding does
// not exist" case (null) without LRUCache rejecting nullish values.
export const agentBindingCache = new LRUCache<string, { v: unknown }>({
    max: TRAITS_CACHE_MAX,
    ttl: CACHE_TTL_MS,
});
export const agentBindingNullTtlMs = CANVAS_INFO_CACHE_TTL_MS;

// Transform history — mutable (each canvas burn appends a version) but the
// /info endpoint only needs eventual consistency. 30s TTL keeps the hot path
// fast without making versions feel stuck.
export const transformHistoryCache = new LRUCache<number, unknown[]>({
    max: CACHE_MAX_ENTRIES,
    ttl: 30_000,
});

// Composed response cache for the /agents/* endpoints — keyed by route name
// + tokenId so repeated hits for the same agent serve straight from memory
// without re-running persona generation. TTL matches canvasInfoCache so
// `canvas.level` / `customized` updates aren't held back.
export const agentResponseCache = new LRUCache<string, NonNullable<unknown>>({
    max: CACHE_MAX_ENTRIES,
    ttl: CANVAS_INFO_CACHE_TTL_MS,
});

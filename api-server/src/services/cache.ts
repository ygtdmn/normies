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

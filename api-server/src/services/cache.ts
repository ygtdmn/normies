import { LRUCache } from "lru-cache";
import { CACHE_MAX_ENTRIES, CACHE_TTL_MS } from "../config.js";

export const imageDataCache = new LRUCache<number, Uint8Array>({
    max: CACHE_MAX_ENTRIES,
    ttl: CACHE_TTL_MS,
});

export const traitsCache = new LRUCache<number, `0x${string}`>({
    max: CACHE_MAX_ENTRIES,
    ttl: CACHE_TTL_MS,
});

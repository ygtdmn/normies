import { LRUCache } from "lru-cache";
import { CACHE_MAX_ENTRIES, CACHE_TTL_MS, CANVAS_CACHE_TTL_MS, CANVAS_INFO_CACHE_TTL_MS } from "../config.js";

export const imageDataCache = new LRUCache<number, Uint8Array>({
    max: CACHE_MAX_ENTRIES,
    ttl: CACHE_TTL_MS,
});

export const traitsCache = new LRUCache<number, `0x${string}`>({
    max: CACHE_MAX_ENTRIES,
    ttl: CACHE_TTL_MS,
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

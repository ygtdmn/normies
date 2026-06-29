import { hexToBytes } from "viem";
import { countPixels } from "../lib/traits.js";
import type { MetadataAttribute } from "../lib/metadata.js";
import { ZOMBIE_ENABLED } from "../config.js";
import { getCanvasInfo, getTransformData } from "./canvas-data.js";
import { getImageData } from "./token-data.js";
import {
    getIndexedZombieConversions,
    getIndexedZombieConversionsForToken,
    getIndexedZombieConversionsForWallet,
    getIndexedZombieState,
    getIndexedZombieStatus,
    type IndexedZombieConversion,
    type IndexedZombieStatus,
} from "./ponder-data.js";
import { zombieBitmapCache, zombieInfoCache, type ZombieInfo } from "./cache.js";

export async function getZombieInfo(tokenId: number): Promise<ZombieInfo> {
    if (!ZOMBIE_ENABLED) return emptyZombieInfo(tokenId);

    const cached = zombieInfoCache.get(tokenId);
    if (cached) return cached;

    const state = await getIndexedZombieState(tokenId);
    const info: ZombieInfo = {
        tokenId: state.tokenId,
        isZombie: state.isZombie,
        poolIndex: state.poolIndex,
        bitmap: state.bitmap,
        attributesJson: state.attributesJson,
        qualifyingWallet: state.qualifyingWallet,
        commitId: state.commitId,
        blockNumber: state.blockNumber,
        timestamp: state.timestamp,
        txHash: state.txHash,
    };
    zombieInfoCache.set(tokenId, info);
    if (info.bitmap) zombieBitmapCache.set(tokenId, hexToBytes(info.bitmap));
    return info;
}

export async function getZombieBitmap(tokenId: number): Promise<Uint8Array> {
    const cached = zombieBitmapCache.get(tokenId);
    if (cached) return cached;

    const info = await getZombieInfo(tokenId);
    if (!info.isZombie || !info.bitmap) {
        throw new Error(`Token ${tokenId} is not a zombie`);
    }
    const bytes = hexToBytes(info.bitmap);
    zombieBitmapCache.set(tokenId, bytes);
    return bytes;
}

export async function getActiveBaseImageData(tokenId: number): Promise<Uint8Array> {
    const info = await getZombieInfo(tokenId);
    if (info.isZombie) return getZombieBitmap(tokenId);
    return getImageData(tokenId);
}

/**
 * Base image as it stood at a given block: the zombie bitmap if the token had
 * already converted by `blockNumber`, otherwise the original mint art.
 *
 * The renderer always composites a transform layer onto the *active* base, so a
 * transform recorded after conversion is a diff from the zombie bitmap, while
 * one recorded before conversion is a diff from the original art. History
 * endpoints need this per-version base to reconstruct each version faithfully —
 * compositing every version onto the original art corrupts zombie-era edits.
 */
export async function getBaseImageDataAtBlock(tokenId: number, blockNumber: bigint): Promise<Uint8Array> {
    const info = await getZombieInfo(tokenId);
    if (info.isZombie && info.blockNumber !== null && blockNumber >= BigInt(info.blockNumber)) {
        return getZombieBitmap(tokenId);
    }
    return getImageData(tokenId);
}

export async function getActiveImageData(tokenId: number): Promise<Uint8Array> {
    const [base, canvasInfo] = await Promise.all([
        getActiveBaseImageData(tokenId),
        getCanvasInfo(tokenId),
    ]);
    if (!canvasInfo.customized) return base;

    const transform = await getTransformData(tokenId);
    return composite(base, transform);
}

export async function getZombieAttributes(tokenId: number): Promise<MetadataAttribute[]> {
    const info = await getZombieInfo(tokenId);
    if (!info.isZombie || !info.attributesJson) return [];
    return parseZombieAttributes(info.attributesJson);
}

export function parseZombieAttributes(fragment: string): MetadataAttribute[] {
    const parsed = JSON.parse(`[${fragment}]`) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.flatMap((item): MetadataAttribute[] => {
        if (!item || typeof item !== "object") return [];
        const record = item as Record<string, unknown>;
        if (typeof record.trait_type !== "string") return [];
        const value = record.value;
        if (typeof value !== "string" && typeof value !== "number") return [];
        const displayType = typeof record.display_type === "string" ? record.display_type : undefined;
        return [{ trait_type: record.trait_type, value, display_type: displayType }];
    });
}

export async function getZombieDisplayPixelCount(tokenId: number): Promise<number> {
    const imageData = await getActiveImageData(tokenId);
    return countPixels(imageData);
}

export async function getZombieConversions(
    limit = 50,
    offset = 0,
): Promise<IndexedZombieConversion[]> {
    if (!ZOMBIE_ENABLED) return [];
    return getIndexedZombieConversions(limit, offset);
}

export async function getZombieConversionsForWallet(
    address: string,
    limit = 50,
    offset = 0,
): Promise<IndexedZombieConversion[]> {
    if (!ZOMBIE_ENABLED) return [];
    return getIndexedZombieConversionsForWallet(address, limit, offset);
}

export async function getZombieConversionsForToken(tokenId: number): Promise<IndexedZombieConversion[]> {
    if (!ZOMBIE_ENABLED) return [];
    return getIndexedZombieConversionsForToken(tokenId);
}

export async function getZombieStatus(): Promise<IndexedZombieStatus> {
    if (!ZOMBIE_ENABLED) {
        return {
            paused: true,
            merkleRoot: null,
            seedBlock: null,
            seed: null,
            seedLocked: false,
            poolSize: 0,
            poolSealed: false,
            blockNumber: null,
            timestamp: null,
            txHash: null,
        };
    }
    return getIndexedZombieStatus();
}

function emptyZombieInfo(tokenId: number): ZombieInfo {
    return {
        tokenId: tokenId.toString(),
        isZombie: false,
        poolIndex: null,
        bitmap: null,
        attributesJson: null,
        qualifyingWallet: null,
        commitId: null,
        blockNumber: null,
        timestamp: null,
        txHash: null,
    };
}

function composite(base: Uint8Array, overlay: Uint8Array): Uint8Array {
    const result = new Uint8Array(200);
    for (let i = 0; i < 200; i++) result[i] = base[i]! ^ overlay[i]!;
    return result;
}

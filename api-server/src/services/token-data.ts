import { hexToBytes } from "viem";
import { imageDataCache, traitsCache, decodedTraitsCache } from "./cache.js";
import { getIndexedTokenData, getIndexedTokenDataCount } from "./ponder-data.js";
import { decodeTraits } from "../lib/traits.js";

export async function getImageData(tokenId: number): Promise<Uint8Array> {
    const cached = imageDataCache.get(tokenId);
    if (cached) return cached;

    const data = await getIndexedTokenData(tokenId);
    const bytes = hexToBytes(data.rawImageData);
    imageDataCache.set(tokenId, bytes);
    traitsCache.set(tokenId, data.traitsHex);
    return bytes;
}

export async function getTraitsHex(tokenId: number): Promise<`0x${string}`> {
    const cached = traitsCache.get(tokenId);
    if (cached) return cached;

    const data = await getIndexedTokenData(tokenId);
    traitsCache.set(tokenId, data.traitsHex);
    imageDataCache.set(tokenId, hexToBytes(data.rawImageData));
    return data.traitsHex;
}

export async function getTokenData(
    tokenId: number
): Promise<{ imageData: Uint8Array; traitsHex: `0x${string}` }> {
    const cachedImage = imageDataCache.get(tokenId);
    const cachedTraits = traitsCache.get(tokenId);
    if (cachedImage && cachedTraits) {
        return { imageData: cachedImage, traitsHex: cachedTraits };
    }

    const data = await getIndexedTokenData(tokenId);
    const imageData = hexToBytes(data.rawImageData);
    imageDataCache.set(tokenId, imageData);
    traitsCache.set(tokenId, data.traitsHex);
    return { imageData, traitsHex: data.traitsHex };
}

/**
 * Decoded mint traits as a flat Record<traitName, value>. Cached because
 * traits are immutable post-mint and decoding runs on every persona request.
 */
export async function getDecodedTraits(tokenId: number): Promise<Record<string, string>> {
    const cached = decodedTraitsCache.get(tokenId);
    if (cached) return cached;

    const hex = await getTraitsHex(tokenId);
    const { attributes } = decodeTraits(hex);
    const record: Record<string, string> = {};
    for (const { trait_type, value } of attributes) record[trait_type] = value;

    decodedTraitsCache.set(tokenId, record);
    return record;
}

export async function isTokenDataSet(tokenId: number): Promise<boolean> {
    try {
        await getIndexedTokenData(tokenId);
        return true;
    } catch (err) {
        if (err instanceof Error && err.message.startsWith("Ponder API 404:")) return false;
        throw err;
    }
}

export async function getTotalSupply(): Promise<number> {
    return getIndexedTokenDataCount();
}

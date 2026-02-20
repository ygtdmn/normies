import { hexToBytes } from "viem";
import { publicClient } from "./chain.js";
import { imageDataCache, traitsCache } from "./cache.js";
import { STORAGE_ADDRESS, NORMIES_ADDRESS } from "../config.js";

const StorageABI = [
    {
        type: "function",
        name: "getTokenRawImageData",
        inputs: [{ name: "tokenId", type: "uint256" }],
        outputs: [{ name: "", type: "bytes" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "getTokenTraits",
        inputs: [{ name: "tokenId", type: "uint256" }],
        outputs: [{ name: "", type: "bytes8" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "isTokenDataSet",
        inputs: [{ name: "tokenId", type: "uint256" }],
        outputs: [{ name: "", type: "bool" }],
        stateMutability: "view",
    },
] as const;

const NormiesABI = [
    {
        type: "function",
        name: "totalSupply",
        inputs: [],
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
    },
] as const;

export async function getImageData(tokenId: number): Promise<Uint8Array> {
    const cached = imageDataCache.get(tokenId);
    if (cached) return cached;

    const data = await publicClient.readContract({
        address: STORAGE_ADDRESS,
        abi: StorageABI,
        functionName: "getTokenRawImageData",
        args: [BigInt(tokenId)],
    });

    const bytes = hexToBytes(data);
    imageDataCache.set(tokenId, bytes);
    return bytes;
}

export async function getTraitsHex(tokenId: number): Promise<`0x${string}`> {
    const cached = traitsCache.get(tokenId);
    if (cached) return cached;

    const data = await publicClient.readContract({
        address: STORAGE_ADDRESS,
        abi: StorageABI,
        functionName: "getTokenTraits",
        args: [BigInt(tokenId)],
    });

    traitsCache.set(tokenId, data);
    return data;
}

export async function getTokenData(
    tokenId: number
): Promise<{ imageData: Uint8Array; traitsHex: `0x${string}` }> {
    const [imageData, traitsHex] = await Promise.all([
        getImageData(tokenId),
        getTraitsHex(tokenId),
    ]);
    return { imageData, traitsHex };
}

export async function isTokenDataSet(tokenId: number): Promise<boolean> {
    return publicClient.readContract({
        address: STORAGE_ADDRESS,
        abi: StorageABI,
        functionName: "isTokenDataSet",
        args: [BigInt(tokenId)],
    });
}

export async function getTotalSupply(): Promise<number> {
    const supply = await publicClient.readContract({
        address: NORMIES_ADDRESS,
        abi: NormiesABI,
        functionName: "totalSupply",
    });
    return Number(supply);
}

import { hexToBytes } from "viem";
import { publicClient } from "./chain.js";
import { getImageData } from "./token-data.js";
import { transformDataCache, isTransformedCache, canvasInfoCache, type CanvasInfo } from "./cache.js";
import { CANVAS_ADDRESS, CANVAS_STORAGE_ADDRESS, CANVAS_ENABLED } from "../config.js";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const EMPTY_BITMAP = new Uint8Array(200);

const CanvasStorageABI = [
    {
        type: "function",
        name: "isTransformed",
        inputs: [{ name: "tokenId", type: "uint256" }],
        outputs: [{ name: "", type: "bool" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "getTransformedImageData",
        inputs: [{ name: "tokenId", type: "uint256" }],
        outputs: [{ name: "", type: "bytes" }],
        stateMutability: "view",
    },
] as const;

const CanvasABI = [
    {
        type: "function",
        name: "actionPoints",
        inputs: [{ name: "tokenId", type: "uint256" }],
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "getLevel",
        inputs: [{ name: "tokenId", type: "uint256" }],
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "delegates",
        inputs: [{ name: "tokenId", type: "uint256" }],
        outputs: [{ name: "", type: "address" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "delegateSetBy",
        inputs: [{ name: "tokenId", type: "uint256" }],
        outputs: [{ name: "", type: "address" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "paused",
        inputs: [],
        outputs: [{ name: "", type: "bool" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "maxBurnPercent",
        inputs: [],
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "tierThresholds",
        inputs: [{ name: "index", type: "uint256" }],
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "tierMinPercents",
        inputs: [{ name: "index", type: "uint256" }],
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
    },
] as const;

export async function isTransformed(tokenId: number): Promise<boolean> {
    if (!CANVAS_ENABLED) return false;

    const cached = isTransformedCache.get(tokenId);
    if (cached !== undefined) return cached;

    const result = await publicClient.readContract({
        address: CANVAS_STORAGE_ADDRESS!,
        abi: CanvasStorageABI,
        functionName: "isTransformed",
        args: [BigInt(tokenId)],
    });

    isTransformedCache.set(tokenId, result);
    return result;
}

export async function getTransformData(tokenId: number): Promise<Uint8Array> {
    if (!CANVAS_ENABLED) return EMPTY_BITMAP;

    const transformed = await isTransformed(tokenId);
    if (!transformed) return EMPTY_BITMAP;

    const cached = transformDataCache.get(tokenId);
    if (cached) return cached;

    const data = await publicClient.readContract({
        address: CANVAS_STORAGE_ADDRESS!,
        abi: CanvasStorageABI,
        functionName: "getTransformedImageData",
        args: [BigInt(tokenId)],
    });

    const bytes = hexToBytes(data);
    transformDataCache.set(tokenId, bytes);
    return bytes;
}

export async function getCompositedImageData(tokenId: number): Promise<Uint8Array> {
    const original = await getImageData(tokenId);

    const transformed = await isTransformed(tokenId);
    if (!transformed) return original;

    const transform = await getTransformData(tokenId);
    return composite(original, transform);
}

export async function getCanvasInfo(tokenId: number): Promise<CanvasInfo> {
    if (!CANVAS_ENABLED) {
        return { actionPoints: 0, level: 1, customized: false, delegate: ZERO_ADDRESS, delegateSetBy: ZERO_ADDRESS };
    }

    const cached = canvasInfoCache.get(tokenId);
    if (cached) return cached;

    const results = await publicClient.multicall({
        contracts: [
            {
                address: CANVAS_ADDRESS!,
                abi: CanvasABI,
                functionName: "actionPoints",
                args: [BigInt(tokenId)],
            },
            {
                address: CANVAS_ADDRESS!,
                abi: CanvasABI,
                functionName: "getLevel",
                args: [BigInt(tokenId)],
            },
            {
                address: CANVAS_ADDRESS!,
                abi: CanvasABI,
                functionName: "delegates",
                args: [BigInt(tokenId)],
            },
            {
                address: CANVAS_ADDRESS!,
                abi: CanvasABI,
                functionName: "delegateSetBy",
                args: [BigInt(tokenId)],
            },
            {
                address: CANVAS_STORAGE_ADDRESS!,
                abi: CanvasStorageABI,
                functionName: "isTransformed",
                args: [BigInt(tokenId)],
            },
        ],
    });

    const info: CanvasInfo = {
        actionPoints: Number(results[0].result ?? 0n),
        level: Number(results[1].result ?? 1n),
        customized: (results[4].result as boolean) ?? false,
        delegate: (results[2].result as string) ?? ZERO_ADDRESS,
        delegateSetBy: (results[3].result as string) ?? ZERO_ADDRESS,
    };

    canvasInfoCache.set(tokenId, info);
    return info;
}

export interface CanvasStatus {
    paused: boolean;
    maxBurnPercent: number;
    tierThresholds: [number, number];
    tierMinPercents: [number, number, number];
}

export async function getCanvasStatus(): Promise<CanvasStatus> {
    const results = await publicClient.multicall({
        contracts: [
            { address: CANVAS_ADDRESS!, abi: CanvasABI, functionName: "paused" },
            { address: CANVAS_ADDRESS!, abi: CanvasABI, functionName: "maxBurnPercent" },
            { address: CANVAS_ADDRESS!, abi: CanvasABI, functionName: "tierThresholds", args: [0n] },
            { address: CANVAS_ADDRESS!, abi: CanvasABI, functionName: "tierThresholds", args: [1n] },
            { address: CANVAS_ADDRESS!, abi: CanvasABI, functionName: "tierMinPercents", args: [0n] },
            { address: CANVAS_ADDRESS!, abi: CanvasABI, functionName: "tierMinPercents", args: [1n] },
            { address: CANVAS_ADDRESS!, abi: CanvasABI, functionName: "tierMinPercents", args: [2n] },
        ],
    });

    return {
        paused: (results[0].result as boolean) ?? false,
        maxBurnPercent: Number(results[1].result ?? 0n),
        tierThresholds: [Number(results[2].result ?? 0n), Number(results[3].result ?? 0n)],
        tierMinPercents: [Number(results[4].result ?? 0n), Number(results[5].result ?? 0n), Number(results[6].result ?? 0n)],
    };
}

function composite(original: Uint8Array, transform: Uint8Array): Uint8Array {
    const result = new Uint8Array(200);
    for (let i = 0; i < 200; i++) {
        result[i] = original[i] ^ transform[i];
    }
    return result;
}

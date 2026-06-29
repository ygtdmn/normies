import { hexToBytes } from "viem";
import { publicClient } from "./chain.js";
import { transformDataCache, isTransformedCache, canvasInfoCache, type CanvasInfo } from "./cache.js";
import { getIndexedCanvasState, type IndexedCanvasState } from "./ponder-data.js";
import { CANVAS_ADDRESS, CANVAS_ENABLED, CANVAS_STATUS_CACHE_TTL_MS } from "../config.js";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const EMPTY_BITMAP = new Uint8Array(200);

const CanvasABI = [
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

function hydrateCanvasCaches(tokenId: number, state: IndexedCanvasState): CanvasInfo {
    const actionPoints = Number(BigInt(state.actionPoints));
    const customized = state.customized;
    const info: CanvasInfo = {
        actionPoints,
        level: Math.floor(actionPoints / 10) + 1,
        customized,
        delegate: state.delegate ?? ZERO_ADDRESS,
        delegateSetBy: state.delegateSetBy ?? ZERO_ADDRESS,
    };

    canvasInfoCache.set(tokenId, info);
    isTransformedCache.set(tokenId, customized);
    if (customized && state.latestTransformBitmap) {
        transformDataCache.set(tokenId, hexToBytes(state.latestTransformBitmap));
    }

    return info;
}

async function getCanvasState(tokenId: number): Promise<IndexedCanvasState> {
    const state = await getIndexedCanvasState(tokenId);
    hydrateCanvasCaches(tokenId, state);
    return state;
}

export async function isTransformed(tokenId: number): Promise<boolean> {
    if (!CANVAS_ENABLED) return false;

    const cached = isTransformedCache.get(tokenId);
    if (cached !== undefined) return cached;

    const state = await getCanvasState(tokenId);
    return state.customized;
}

export async function getTransformData(tokenId: number): Promise<Uint8Array> {
    if (!CANVAS_ENABLED) return EMPTY_BITMAP;

    const cached = transformDataCache.get(tokenId);
    if (cached) return cached;

    const state = await getCanvasState(tokenId);
    if (!state.customized) return EMPTY_BITMAP;
    if (!state.latestTransformBitmap) {
        throw new Error(`Missing transform bitmap for customized token ${tokenId}`);
    }

    const bytes = hexToBytes(state.latestTransformBitmap);
    transformDataCache.set(tokenId, bytes);
    return bytes;
}

export async function getCanvasInfo(tokenId: number): Promise<CanvasInfo> {
    if (!CANVAS_ENABLED) {
        return { actionPoints: 0, level: 1, customized: false, delegate: ZERO_ADDRESS, delegateSetBy: ZERO_ADDRESS };
    }

    const cached = canvasInfoCache.get(tokenId);
    if (cached) return cached;

    const state = await getIndexedCanvasState(tokenId);
    return hydrateCanvasCaches(tokenId, state);
}

export interface CanvasStatus {
    paused: boolean;
    maxBurnPercent: number;
    tierThresholds: [number, number];
    tierMinPercents: [number, number, number];
}

let canvasStatusCache: { value: CanvasStatus; expiresAt: number } | undefined;

export async function getCanvasStatus(): Promise<CanvasStatus> {
    if (canvasStatusCache && canvasStatusCache.expiresAt > Date.now()) {
        return canvasStatusCache.value;
    }

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

    const status: CanvasStatus = {
        paused: (results[0].result as boolean) ?? false,
        maxBurnPercent: Number(results[1].result ?? 0n),
        tierThresholds: [Number(results[2].result ?? 0n), Number(results[3].result ?? 0n)],
        tierMinPercents: [Number(results[4].result ?? 0n), Number(results[5].result ?? 0n), Number(results[6].result ?? 0n)],
    };
    canvasStatusCache = { value: status, expiresAt: Date.now() + CANVAS_STATUS_CACHE_TTL_MS };
    return status;
}

import { hexToBytes } from "viem";
import { publicClient } from "./chain.js";
import { transformDataCache, isTransformedCache, canvasInfoCache, type CanvasInfo } from "./cache.js";
import { getIndexedCanvasState, type IndexedCanvasState } from "./ponder-data.js";
import { getCanvasSinks } from "./pixel-market-data.js";
import { emptyBitmap, fitToGrid } from "../lib/bitmap.js";
import {
    CANVAS_ADDRESS,
    CANVAS_ENABLED,
    CANVAS_STATUS_CACHE_TTL_MS,
    CANVAS_V2_ADDRESS,
    MARKET_ADDRESS,
    PIXEL_MARKET_ENABLED,
} from "../config.js";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

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
    {
        type: "function",
        name: "burnTiers",
        inputs: [],
        outputs: [
            { name: "thresholds", type: "uint256[]" },
            { name: "minPercents", type: "uint256[]" },
        ],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "enlargePrice",
        inputs: [{ name: "size", type: "uint256" }],
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "blankCanvasPrice",
        inputs: [],
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
    },
] as const;

const MarketABI = [
    {
        type: "function",
        name: "treasuryRecipient",
        inputs: [],
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
        name: "feeBps",
        inputs: [],
        outputs: [{ name: "", type: "uint16" }],
        stateMutability: "view",
    },
    {
        type: "function",
        name: "revenueShareBps",
        inputs: [],
        outputs: [{ name: "", type: "uint16" }],
        stateMutability: "view",
    },
] as const;

function hydrateCanvasCaches(tokenId: number, state: IndexedCanvasState): CanvasInfo {
    const actionPoints = Number(BigInt(state.actionPoints));
    const customized = state.customized;
    const lockedPixels = state.lockedPixels ?? 0;
    const info: CanvasInfo = {
        actionPoints,
        level: Math.floor(actionPoints / 10) + 1,
        customized,
        delegate: state.delegate ?? ZERO_ADDRESS,
        delegateSetBy: state.delegateSetBy ?? ZERO_ADDRESS,
        gridSize: state.gridSize ?? 40,
        baseCleared: state.baseCleared ?? false,
        migrated: state.migrated ?? false,
        lockedPixels,
        freePixels: Math.max(0, actionPoints - lockedPixels),
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

/**
 * The token's overlay, brought to its current grid size (an overlay written
 * before an enlargement is 40x40 and gets embedded). All-zero when untouched.
 */
export async function getTransformData(tokenId: number): Promise<Uint8Array> {
    const info = await getCanvasInfo(tokenId);
    if (!CANVAS_ENABLED || !info.customized) return emptyBitmap(info.gridSize);

    const cached = transformDataCache.get(tokenId);
    if (cached) return fitToGrid(cached, info.gridSize);

    const state = await getCanvasState(tokenId);
    if (!state.customized) return emptyBitmap(info.gridSize);
    if (!state.latestTransformBitmap) {
        throw new Error(`Missing transform bitmap for customized token ${tokenId}`);
    }

    const bytes = hexToBytes(state.latestTransformBitmap);
    transformDataCache.set(tokenId, bytes);
    return fitToGrid(bytes, info.gridSize);
}

export function emptyCanvasInfo(): CanvasInfo {
    return {
        actionPoints: 0,
        level: 1,
        customized: false,
        delegate: ZERO_ADDRESS,
        delegateSetBy: ZERO_ADDRESS,
        gridSize: 40,
        baseCleared: false,
        migrated: false,
        lockedPixels: 0,
        freePixels: 0,
    };
}

export async function getCanvasInfo(tokenId: number): Promise<CanvasInfo> {
    if (!CANVAS_ENABLED) return emptyCanvasInfo();

    const cached = canvasInfoCache.get(tokenId);
    if (cached) return cached;

    const state = await getIndexedCanvasState(tokenId);
    return hydrateCanvasCaches(tokenId, state);
}

/** Block at which the token's base art was cleared, or null. Used by history to render old versions. */
export async function getBaseClearedBlock(tokenId: number): Promise<bigint | null> {
    if (!PIXEL_MARKET_ENABLED) return null;
    const info = await getCanvasInfo(tokenId);
    if (!info.baseCleared) return null;
    const { events } = await getCanvasSinks({ tokenId, kind: "clearBase", limit: 1 });
    const event = events[0];
    return event ? BigInt(event.blockNumber) : null;
}

export interface CanvasStatus {
    paused: boolean;
    maxBurnPercent: number;
    /** Any number of tiers: minPercents has one more entry than thresholds. */
    tierThresholds: number[];
    tierMinPercents: number[];
    /** Present once the Pixel Market stack is configured. */
    pixelMarket?: {
        canvasAddress: string;
        marketAddress: string;
        enlargePrices: Record<"50" | "60" | "70" | "80", number>;
        blankCanvasPrice: number;
        treasury: string;
        market: { paused: boolean; feeBps: number; revenueShareBps: number };
    };
}

let canvasStatusCache: { value: CanvasStatus; expiresAt: number } | undefined;

export async function getCanvasStatus(): Promise<CanvasStatus> {
    if (canvasStatusCache && canvasStatusCache.expiresAt > Date.now()) {
        return canvasStatusCache.value;
    }

    // Burn config lives on whichever canvas is live: V2 once the market stack is deployed.
    const canvasAddress = (PIXEL_MARKET_ENABLED ? CANVAS_V2_ADDRESS : CANVAS_ADDRESS)!;
    const results = await publicClient.multicall({
        contracts: [
            { address: canvasAddress, abi: CanvasABI, functionName: "paused" },
            { address: canvasAddress, abi: CanvasABI, functionName: "maxBurnPercent" },
            { address: canvasAddress, abi: CanvasABI, functionName: "tierThresholds", args: [0n] },
            { address: canvasAddress, abi: CanvasABI, functionName: "tierThresholds", args: [1n] },
            { address: canvasAddress, abi: CanvasABI, functionName: "tierMinPercents", args: [0n] },
            { address: canvasAddress, abi: CanvasABI, functionName: "tierMinPercents", args: [1n] },
            { address: canvasAddress, abi: CanvasABI, functionName: "tierMinPercents", args: [2n] },
        ],
    });

    const status: CanvasStatus = {
        paused: (results[0].result as boolean) ?? false,
        maxBurnPercent: Number(results[1].result ?? 0n),
        tierThresholds: [Number(results[2].result ?? 0n), Number(results[3].result ?? 0n)],
        tierMinPercents: [Number(results[4].result ?? 0n), Number(results[5].result ?? 0n), Number(results[6].result ?? 0n)],
    };
    if (PIXEL_MARKET_ENABLED) {
        // Canvas V2 has any number of tiers and returns them in one call.
        const [thresholds, minPercents] = (await publicClient.readContract({
            address: canvasAddress,
            abi: CanvasABI,
            functionName: "burnTiers",
        })) as readonly [readonly bigint[], readonly bigint[]];
        status.tierThresholds = thresholds.map(Number);
        status.tierMinPercents = minPercents.map(Number);
    }

    if (PIXEL_MARKET_ENABLED) {
        const extra = await publicClient.multicall({
            contracts: [
                { address: CANVAS_V2_ADDRESS!, abi: CanvasABI, functionName: "enlargePrice", args: [50n] },
                { address: CANVAS_V2_ADDRESS!, abi: CanvasABI, functionName: "enlargePrice", args: [60n] },
                { address: CANVAS_V2_ADDRESS!, abi: CanvasABI, functionName: "enlargePrice", args: [70n] },
                { address: CANVAS_V2_ADDRESS!, abi: CanvasABI, functionName: "enlargePrice", args: [80n] },
                { address: CANVAS_V2_ADDRESS!, abi: CanvasABI, functionName: "blankCanvasPrice" },
                // The fee treasury lives on the market; the canvas has none.
                { address: MARKET_ADDRESS!, abi: MarketABI, functionName: "treasuryRecipient" },
                { address: MARKET_ADDRESS!, abi: MarketABI, functionName: "paused" },
                { address: MARKET_ADDRESS!, abi: MarketABI, functionName: "feeBps" },
                { address: MARKET_ADDRESS!, abi: MarketABI, functionName: "revenueShareBps" },
            ],
        });
        status.pixelMarket = {
            canvasAddress: CANVAS_V2_ADDRESS!,
            marketAddress: MARKET_ADDRESS!,
            enlargePrices: {
                "50": Number(extra[0].result ?? 0n),
                "60": Number(extra[1].result ?? 0n),
                "70": Number(extra[2].result ?? 0n),
                "80": Number(extra[3].result ?? 0n),
            },
            blankCanvasPrice: Number(extra[4].result ?? 0n),
            treasury: (extra[5].result as string) ?? ZERO_ADDRESS,
            market: {
                paused: (extra[6].result as boolean) ?? true,
                feeBps: Number(extra[7].result ?? 0),
                revenueShareBps: Number(extra[8].result ?? 0),
            },
        };
    }

    canvasStatusCache = { value: status, expiresAt: Date.now() + CANVAS_STATUS_CACHE_TTL_MS };
    return status;
}

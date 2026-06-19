import { LEGENDARY_CANVAS_ENABLED } from "../config.js";
import {
    getIndexedLegendaryCanvases,
    getIndexedLegendaryCanvasState,
    type IndexedLegendaryCanvasState,
} from "./ponder-data.js";
import { legendaryCanvasCache, type LegendaryCanvasInfo } from "./cache.js";

export async function getLegendaryCanvasInfo(tokenId: number): Promise<LegendaryCanvasInfo> {
    if (!LEGENDARY_CANVAS_ENABLED) return emptyLegendaryCanvasInfo(tokenId);

    const cached = legendaryCanvasCache.get(tokenId);
    if (cached) return cached;

    const state = await getIndexedLegendaryCanvasState(tokenId);
    const info: LegendaryCanvasInfo = {
        tokenId: state.tokenId,
        isLegendary: state.isLegendary,
        artistName: state.artistName,
        operator: state.operator,
        blockNumber: state.blockNumber,
        timestamp: state.timestamp,
        txHash: state.txHash,
    };
    legendaryCanvasCache.set(tokenId, info);
    return info;
}

export async function getLegendaryCanvases(limit = 50, offset = 0): Promise<IndexedLegendaryCanvasState[]> {
    if (!LEGENDARY_CANVAS_ENABLED) return [];
    return getIndexedLegendaryCanvases(limit, offset);
}

function emptyLegendaryCanvasInfo(tokenId: number): LegendaryCanvasInfo {
    return {
        tokenId: tokenId.toString(),
        isLegendary: false,
        artistName: null,
        operator: null,
        blockNumber: null,
        timestamp: null,
        txHash: null,
    };
}

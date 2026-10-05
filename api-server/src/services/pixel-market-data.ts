import { ponderFetch, ponderPost } from "./ponder-data.js";

// ──────────────────────────────────────────────
//  Pixel Market read model: thin typed proxies over the indexer's
//  /pixels/*, /market/* and /canvas/sinks routes.
// ──────────────────────────────────────────────

export interface PixelBalanceData {
    address: string;
    balance: string;
    updatedBlock: string | null;
}

export interface PixelHolderRow {
    address: string;
    /** wallet + listed + attached: every #PIXEL the wallet controls. */
    balance: string;
    wallet: string;
    /** In the wallet's open market listings. */
    listed: string;
    /** On the Normies the wallet owns. */
    attached: string;
    updatedBlock: string;
}

export interface TokenPixelsData {
    tokenId: string;
    attached: string;
    locked: string;
    free: string;
    gridSize: number;
    baseCleared: boolean;
    migrated: boolean;
    customized: boolean;
    blockNumber: string;
    owner?: string | null;
}

export interface PixelLedgerEventData {
    id: string;
    kind: "move" | "attached";
    from: string | null;
    to: string | null;
    tokenId: string | null;
    amount: string;
    newAttached: string | null;
    reason: string | null;
    blockNumber: string;
    timestamp: string;
    txHash: string;
    logIndex: number;
}

export interface PixelSupplyData {
    totalWallet: string;
    totalAttached: string;
    totalMigrated: number;
    wallets: number;
    blockNumber: string | null;
    timestamp: string | null;
}

export type ListingStatus = "active" | "filled" | "cancelled";

export interface MarketListingData {
    listingId: string;
    seller: string;
    pricePerPixel: string;
    amount: number;
    remaining: number;
    partialFill: boolean;
    expiry: string;
    status: ListingStatus;
    blockNumber: string;
    timestamp: string;
    txHash: string;
    updatedBlockNumber: string;
    updatedTimestamp: string;
    updatedTxHash: string;
}

export interface MarketFillData {
    id: string;
    listingId: string;
    buyer: string;
    seller: string;
    amount: number;
    pricePerPixel: string;
    grossWei: string;
    feeWei: string;
    blockNumber: string;
    timestamp: string;
    txHash: string;
    logIndex: number;
}

export interface MarketStatsData {
    volumeWei: string;
    feesWei: string;
    feesCollectedWei: string;
    pixelsTraded: string;
    fills: number;
    listings: number;
    feeBps: number;
    revenueShareBps: number;
    paused: boolean;
    activeListings: number;
    pixelsListed: number;
    bestAskWei: string | null;
    lastPriceWei: string | null;
    lastFillTimestamp: string | null;
    volume24hWei: string;
    pixels24h: number;
    blockNumber: string | null;
    timestamp: string | null;
}

export interface MarketDepthLevel {
    pricePerPixel: string;
    remaining: number;
    listings: number;
    partialRemaining: number;
}

export interface MarketCandle {
    time: number;
    open: string;
    high: string;
    low: string;
    close: string;
    volumeWei: string;
    pixels: number;
    fills: number;
}

export interface CanvasSinkEventData {
    id: string;
    tokenId: string;
    kind: "enlarge" | "clearBase";
    fromSize: number | null;
    toSize: number | null;
    cost: string;
    source: string;
    by: string;
    blockNumber: string;
    timestamp: string;
    txHash: string;
}

export type ListingSort = "price-asc" | "price-desc" | "amount-desc" | "newest";

function page(limit: number, offset: number): URLSearchParams {
    return new URLSearchParams({ limit: String(limit), offset: String(offset) });
}

// ── Pixels ──

export async function getPixelBalance(address: string): Promise<PixelBalanceData> {
    return ponderFetch(`/pixels/balance/${address.toLowerCase()}`);
}

export async function getPixelHolders(limit = 50, offset = 0): Promise<{ holders: PixelHolderRow[]; hasMore: boolean }> {
    return ponderFetch(`/pixels/holders?${page(limit, offset).toString()}`);
}

export interface PixelHolderTotals {
    address: string;
    balance: string;
    wallet: string;
    listed: string;
    attached: string;
    normiesWithPixels: number;
}

/** One wallet's #PIXEL, counted like /pixels/holders: wallet + listed + pixels on the Normies it owns. */
export async function getPixelHolder(address: string): Promise<PixelHolderTotals> {
    return ponderFetch(`/pixels/holders/${address.toLowerCase()}`);
}

export async function getTokenPixels(tokenId: number): Promise<TokenPixelsData> {
    return ponderFetch(`/pixels/token/${tokenId}`);
}

export async function getTokenPixelsBatch(tokenIds: (number | string)[]): Promise<Record<string, TokenPixelsData>> {
    const res = await ponderPost<{ tokens: Record<string, TokenPixelsData> }>("/pixels/token/batch", {
        tokenIds: tokenIds.map(String),
    });
    return res.tokens ?? {};
}

export async function getPixelActivity(address: string, limit = 50, offset = 0): Promise<{
    events: PixelLedgerEventData[];
    hasMore: boolean;
}> {
    return ponderFetch(`/pixels/activity/${address.toLowerCase()}?${page(limit, offset).toString()}`);
}

export async function getTokenPixelActivity(tokenId: number, limit = 50, offset = 0): Promise<{
    events: PixelLedgerEventData[];
    hasMore: boolean;
}> {
    return ponderFetch(`/pixels/token/${tokenId}/activity?${page(limit, offset).toString()}`);
}

export async function getPixelSupply(): Promise<PixelSupplyData> {
    return ponderFetch("/pixels/supply");
}

// ── Market ──

export async function getMarketListings(opts: {
    status?: ListingStatus | "all";
    seller?: string;
    sort?: ListingSort;
    partial?: boolean;
    expired?: boolean;
    limit?: number;
    offset?: number;
} = {}): Promise<{ listings: MarketListingData[]; hasMore: boolean }> {
    const params = page(opts.limit ?? 50, opts.offset ?? 0);
    if (opts.status) params.set("status", opts.status);
    if (opts.seller) params.set("seller", opts.seller.toLowerCase());
    if (opts.sort) params.set("sort", opts.sort);
    if (opts.partial !== undefined) params.set("partial", String(opts.partial));
    if (opts.expired) params.set("expired", "true");
    return ponderFetch(`/market/listings?${params.toString()}`);
}

export async function getMarketListing(listingId: string): Promise<MarketListingData & { fills: MarketFillData[] }> {
    return ponderFetch(`/market/listings/${listingId}`);
}

export async function getMarketDepth(): Promise<{ levels: MarketDepthLevel[] }> {
    return ponderFetch("/market/depth");
}

export async function getMarketFills(opts: {
    limit?: number;
    offset?: number;
    afterTimestamp?: string | bigint;
    sort?: "asc" | "desc";
} = {}): Promise<{ fills: MarketFillData[]; count: number; hasMore: boolean; afterTimestamp: string | null }> {
    const params = page(opts.limit ?? 50, opts.offset ?? 0);
    if (opts.afterTimestamp !== undefined) params.set("after_timestamp", opts.afterTimestamp.toString());
    if (opts.sort) params.set("sort", opts.sort);
    return ponderFetch(`/market/fills?${params.toString()}`);
}

export async function getMarketFillsForAddress(address: string, limit = 50, offset = 0): Promise<{
    fills: MarketFillData[];
    hasMore: boolean;
}> {
    return ponderFetch(`/market/fills/address/${address.toLowerCase()}?${page(limit, offset).toString()}`);
}

export async function getMarketStats(): Promise<MarketStatsData> {
    return ponderFetch("/market/stats");
}

export async function getMarketCandles(interval: "1h" | "4h" | "1d", limit = 168): Promise<{
    interval: string;
    candles: MarketCandle[];
}> {
    return ponderFetch(`/market/candles?interval=${interval}&limit=${limit}`);
}

// ── Canvas sinks ──

export async function getCanvasSinks(opts: {
    tokenId?: number;
    kind?: "enlarge" | "clearBase";
    limit?: number;
    offset?: number;
} = {}): Promise<{ events: CanvasSinkEventData[]; hasMore: boolean }> {
    const params = page(opts.limit ?? 50, opts.offset ?? 0);
    if (opts.tokenId !== undefined) params.set("tokenId", String(opts.tokenId));
    if (opts.kind) params.set("kind", opts.kind);
    return ponderFetch(`/canvas/sinks?${params.toString()}`);
}

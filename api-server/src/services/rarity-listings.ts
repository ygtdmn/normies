import {
    NORMIES_ADDRESS,
    OPENSEA_API_KEY,
    OPENSEA_COLLECTION_SLUG,
    RARITY_LISTINGS_REFRESH_MS,
} from "../config.js";

export interface RarityListing {
    tokenId: number;
    priceEth: number;
    currency: string;
    url: string;
}

export interface ListingEvent {
    event: "listed" | "sold" | "cancelled";
    tokenId: number;
    priceEth: number | null;
}

const OPENSEA_ITEM_URL = `https://opensea.io/item/ethereum/${NORMIES_ADDRESS.toLowerCase()}`;

const listings = new Map<number, RarityListing>();
const listeners = new Set<(event: ListingEvent) => void>();
let started = false;
let refreshPromise: Promise<void> | null = null;
let lastFetch = 0;

export function getListingSnapshot(): Map<number, RarityListing> {
    startListingSync();
    return new Map(listings);
}

export function getListingsStatus(): { listed: number; floorPrice: number | null; openseaConnected: boolean; lastFetch: number | null } {
    startListingSync();
    return {
        listed: listings.size,
        floorPrice: getFloorPrice(),
        openseaConnected: !!OPENSEA_API_KEY,
        lastFetch: lastFetch || null,
    };
}

export function subscribeListingEvents(listener: (event: ListingEvent) => void): () => void {
    startListingSync();
    listeners.add(listener);
    return () => listeners.delete(listener);
}

export function refreshListingsSoon(): void {
    startListingSync();
    void refreshListings(false);
}

function startListingSync(): void {
    if (started) return;
    started = true;
    void refreshListings(true);
    setInterval(() => {
        void refreshListings(false);
    }, RARITY_LISTINGS_REFRESH_MS).unref();
}

async function refreshListings(initial: boolean): Promise<void> {
    if (refreshPromise) return refreshPromise;

    refreshPromise = (async () => {
        try {
            if (!OPENSEA_API_KEY) {
                lastFetch = Date.now();
                return;
            }

            const fresh = await fetchAllOpenSeaListings();
            if (initial && listings.size === 0) {
                listings.clear();
                for (const [tokenId, listing] of fresh) listings.set(tokenId, listing);
                lastFetch = Date.now();
                return;
            }

            for (const [tokenId] of listings) {
                if (!fresh.has(tokenId)) {
                    listings.delete(tokenId);
                    broadcast({ event: "sold", tokenId, priceEth: null });
                }
            }

            for (const [tokenId, listing] of fresh) {
                const previous = listings.get(tokenId);
                if (!previous || previous.priceEth !== listing.priceEth) {
                    listings.set(tokenId, listing);
                    broadcast({ event: "listed", tokenId, priceEth: listing.priceEth });
                }
            }

            lastFetch = Date.now();
        } catch {
            lastFetch = Date.now();
        }
    })();

    try {
        await refreshPromise;
    } finally {
        refreshPromise = null;
    }
}

async function fetchAllOpenSeaListings(): Promise<Map<number, RarityListing>> {
    const fresh = new Map<number, RarityListing>();
    let cursor: string | null = null;

    while (true) {
        const url = new URL(`https://api.opensea.io/api/v2/listings/collection/${OPENSEA_COLLECTION_SLUG}/all`);
        url.searchParams.set("limit", "100");
        if (cursor) url.searchParams.set("next", cursor);

        const res = await fetch(url.toString(), {
            headers: { "x-api-key": OPENSEA_API_KEY ?? "", accept: "application/json" },
            signal: AbortSignal.timeout(15_000),
        });
        if (!res.ok) throw new Error(`OpenSea listings fetch failed with HTTP ${res.status}`);

        const data = await res.json() as { listings?: unknown[]; orders?: unknown[]; next?: string | null };
        const orders = data.listings ?? data.orders ?? [];
        if (orders.length === 0) break;

        for (const order of orders) {
            const parsed = parseOpenSeaListing(order);
            if (!parsed) continue;
            const existing = fresh.get(parsed.tokenId);
            if (!existing || parsed.priceEth < existing.priceEth) {
                fresh.set(parsed.tokenId, parsed);
            }
        }

        cursor = data.next ?? null;
        if (!cursor) break;
    }

    return fresh;
}

function parseOpenSeaListing(order: unknown): RarityListing | null {
    const record = order as Record<string, any>;
    let tokenId: number | undefined;

    const offer = record.protocol_data?.parameters?.offer?.[0];
    if (offer?.identifierOrCriteria !== undefined) {
        tokenId = Number.parseInt(String(offer.identifierOrCriteria), 10);
    }
    const asset = record.maker_asset_bundle?.assets?.[0];
    if (asset?.token_id !== undefined) {
        tokenId = Number.parseInt(String(asset.token_id), 10);
    }
    if (tokenId === undefined || Number.isNaN(tokenId)) return null;

    const priceObj = record.price?.current ?? record.price;
    const priceWei = priceObj?.value ?? record.current_price ?? "0";
    const decimals = Number(priceObj?.decimals ?? 18);
    const currency = String(priceObj?.currency ?? "ETH");
    const priceEth = Number.parseFloat(String(priceWei)) / 10 ** decimals;
    if (!Number.isFinite(priceEth)) return null;

    return {
        tokenId,
        priceEth: Math.round(priceEth * 10_000) / 10_000,
        currency,
        url: `${OPENSEA_ITEM_URL}/${tokenId}`,
    };
}

function getFloorPrice(): number | null {
    let min = Infinity;
    for (const listing of listings.values()) {
        if (Number.isFinite(listing.priceEth) && listing.priceEth < min) min = listing.priceEth;
    }
    return Number.isFinite(min) ? min : null;
}

function broadcast(event: ListingEvent): void {
    for (const listener of listeners) listener(event);
}

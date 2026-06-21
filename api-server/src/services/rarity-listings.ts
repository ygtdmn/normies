import {
    LISTING_REMOVAL_GRACE,
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
// tokenId -> consecutive refreshes the token has been absent from OpenSea. Used to
// debounce removals so a transient under-fetch doesn't evict a live listing.
const missStreak = new Map<number, number>();
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

            // OpenSea occasionally answers HTTP 200 with an empty body under load
            // or rate limiting. Never let that wipe a populated snapshot: the diff
            // below would mark every token "sold" and, with the CDN cache on
            // /rarity/*, prices would disappear site-wide for up to ~2 minutes
            // before the next poll restores them. Treat empty-while-populated as a
            // transient miss and keep the previous snapshot.
            if (fresh.size === 0 && listings.size > 0) {
                lastFetch = Date.now();
                return;
            }

            if (initial && listings.size === 0) {
                for (const [tokenId, listing] of fresh) listings.set(tokenId, listing);
                lastFetch = Date.now();
                return;
            }

            // Additions and price changes come straight from OpenSea, so trust them
            // immediately. Seeing a token also clears any pending miss streak.
            for (const [tokenId, listing] of fresh) {
                missStreak.delete(tokenId);
                const previous = listings.get(tokenId);
                if (!previous || previous.priceEth !== listing.priceEth) {
                    listings.set(tokenId, listing);
                    broadcast({ event: "listed", tokenId, priceEth: listing.priceEth });
                }
            }

            // Removals are debounced. A single truncated page (OpenSea ending
            // pagination early under load) can drop a genuinely-listed token —
            // disproportionately the high-priced tail like #235 at 56 ETH — so only
            // evict after it has been absent for LISTING_REMOVAL_GRACE consecutive
            // fetches. This rides out transient under-fetches without flickering
            // prices off and on across the grid.
            for (const [tokenId] of listings) {
                if (fresh.has(tokenId)) continue;
                const misses = (missStreak.get(tokenId) ?? 0) + 1;
                if (misses < LISTING_REMOVAL_GRACE) {
                    missStreak.set(tokenId, misses);
                    continue;
                }
                missStreak.delete(tokenId);
                listings.delete(tokenId);
                broadcast({ event: "sold", tokenId, priceEth: null });
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
    const seenCursors = new Set<string>();
    let cursor: string | null = null;
    const MAX_PAGES = 200; // safety cap (~20k listings) so a misbehaving cursor can't loop forever

    for (let page = 0; page < MAX_PAGES; page++) {
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

        for (const order of orders) {
            const parsed = parseOpenSeaListing(order);
            if (!parsed) continue;
            const existing = fresh.get(parsed.tokenId);
            if (!existing || parsed.priceEth < existing.priceEth) {
                fresh.set(parsed.tokenId, parsed);
            }
        }

        // Paginate purely on the cursor. An intermediate page can legitimately come
        // back empty while more pages remain, so stop only when OpenSea reports no
        // next cursor — never on the first empty page (that truncated the snapshot
        // and made listings flicker). Guard against a repeated cursor too.
        cursor = data.next ?? null;
        if (!cursor || seenCursors.has(cursor)) break;
        seenCursors.add(cursor);
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

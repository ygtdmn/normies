import { OPENSEA_API_KEY, OPENSEA_COLLECTION_SLUG } from "../config.js";
import { publicClient } from "./chain.js";

// ──────────────────────────────────────────────
//  Per-epoch context for the site: when the epoch's block range started and
//  ended, the ETH price on the day it was posted, and the collection's OpenSea
//  sales over the range. A posted epoch never changes, so a complete answer is
//  kept for good; a failed or partial one is retried after a short while.
// ──────────────────────────────────────────────

const RETRY_MS = 10 * 60_000;
const OPENSEA_PAGE_LIMIT = 50;
const OPENSEA_MAX_PAGES = 200; // 10k sales an epoch; past that the answer is marked incomplete

export interface OpenSeaVolume {
    sales: number;
    /** ETH and WETH sales, in wei. Sales paid in other tokens are counted in `otherSales` and left out of the sum. */
    volumeWei: string;
    otherSales: number;
    complete: boolean;
}

export interface EpochContext {
    fromTimestamp: number | null;
    toTimestamp: number | null;
    /** ETH/USD on the UTC day the epoch was posted (CoinGecko daily price). */
    ethUsdAtPost: number | null;
    opensea: OpenSeaVolume | null;
}

interface Cached<T> {
    value: T;
    until: number;
}

const blockTimes = new Map<string, number>();
const prices = new Map<string, Cached<number | null>>();
const sales = new Map<string, Cached<OpenSeaVolume | null>>();
const inFlight = new Map<string, Promise<unknown>>();

function once<T>(key: string, run: () => Promise<T>): Promise<T> {
    const running = inFlight.get(key) as Promise<T> | undefined;
    if (running) return running;
    const p = run().finally(() => inFlight.delete(key));
    inFlight.set(key, p);
    return p;
}

async function blockTime(block: string): Promise<number | null> {
    const known = blockTimes.get(block);
    if (known !== undefined) return known;
    try {
        const b = await publicClient.getBlock({ blockNumber: BigInt(block) });
        const ts = Number(b.timestamp);
        blockTimes.set(block, ts);
        return ts;
    } catch {
        return null;
    }
}

/** CoinGecko's daily ETH/USD for the UTC day of `timestamp`. Days in the past never change. */
export async function ethUsdOn(timestamp: number): Promise<number | null> {
    const d = new Date(timestamp * 1000);
    const day = `${String(d.getUTCDate()).padStart(2, "0")}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${d.getUTCFullYear()}`;
    const cached = prices.get(day);
    if (cached && cached.until > Date.now()) return cached.value;
    return once(`price:${day}`, async () => {
        let value: number | null = null;
        try {
            const res = await fetch(
                `https://api.coingecko.com/api/v3/coins/ethereum/history?date=${day}&localization=false`,
                { headers: { accept: "application/json" }, signal: AbortSignal.timeout(10_000) },
            );
            if (res.ok) {
                const data = (await res.json()) as { market_data?: { current_price?: { usd?: number } } };
                const usd = data.market_data?.current_price?.usd;
                if (typeof usd === "number" && Number.isFinite(usd) && usd > 0) value = usd;
            }
        } catch {
            // Unreachable or rate limited: retried later.
        }
        // Today's daily price is still moving; only a past day is final.
        const final = value !== null && Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1) <= Date.now();
        prices.set(day, { value, until: final ? Number.POSITIVE_INFINITY : Date.now() + RETRY_MS });
        return value;
    });
}

interface OpenSeaEvent {
    event_type?: string;
    payment?: { quantity?: string; decimals?: number; symbol?: string } | null;
}

/** The collection's OpenSea sales with event_timestamp in [from, to]. */
async function fetchOpenSeaSales(from: number, to: number): Promise<OpenSeaVolume | null> {
    if (!OPENSEA_API_KEY) return null;
    let volume = 0n;
    let count = 0;
    let other = 0;
    let cursor: string | null = null;
    const seen = new Set<string>();
    for (let page = 0; page < OPENSEA_MAX_PAGES; page++) {
        const url = new URL(`https://api.opensea.io/api/v2/events/collection/${OPENSEA_COLLECTION_SLUG}`);
        url.searchParams.set("event_type", "sale");
        url.searchParams.set("after", String(from - 1));
        url.searchParams.set("before", String(to + 1));
        url.searchParams.set("limit", String(OPENSEA_PAGE_LIMIT));
        if (cursor) url.searchParams.set("next", cursor);
        const res = await fetch(url.toString(), {
            headers: { "x-api-key": OPENSEA_API_KEY, accept: "application/json" },
            signal: AbortSignal.timeout(15_000),
        });
        if (!res.ok) throw new Error(`OpenSea events fetch failed with HTTP ${res.status}`);
        const data = (await res.json()) as { asset_events?: OpenSeaEvent[]; next?: string | null };
        for (const event of data.asset_events ?? []) {
            if (event.event_type && event.event_type !== "sale") continue;
            const symbol = event.payment?.symbol?.toUpperCase();
            const decimals = Number(event.payment?.decimals ?? 18);
            count += 1;
            if ((symbol === "ETH" || symbol === "WETH") && decimals === 18 && event.payment?.quantity) {
                volume += BigInt(event.payment.quantity);
            } else {
                other += 1;
            }
        }
        cursor = data.next ?? null;
        if (!cursor || seen.has(cursor)) {
            return { sales: count, volumeWei: volume.toString(), otherSales: other, complete: true };
        }
        seen.add(cursor);
    }
    return { sales: count, volumeWei: volume.toString(), otherSales: other, complete: false };
}

async function openSeaVolume(epochId: string, from: number, to: number): Promise<OpenSeaVolume | null> {
    const cached = sales.get(epochId);
    if (cached && cached.until > Date.now()) return cached.value;
    return once(`opensea:${epochId}`, async () => {
        let value: OpenSeaVolume | null = null;
        try {
            value = await fetchOpenSeaSales(from, to);
        } catch {
            value = null;
        }
        // A finished range only gains late-indexed sales for a little while; keep a complete answer after a day.
        const settled = value?.complete && to * 1000 + 24 * 3_600_000 <= Date.now();
        sales.set(epochId, { value, until: settled ? Number.POSITIVE_INFINITY : Date.now() + RETRY_MS });
        return value;
    });
}

export async function epochContext(epoch: {
    epochId: string;
    fromBlock: string;
    toBlock: string;
    timestamp: string;
}): Promise<EpochContext> {
    const [fromTimestamp, toTimestamp] = await Promise.all([blockTime(epoch.fromBlock), blockTime(epoch.toBlock)]);
    const [ethUsdAtPost, opensea] = await Promise.all([
        ethUsdOn(Number(epoch.timestamp)),
        fromTimestamp !== null && toTimestamp !== null ? openSeaVolume(epoch.epochId, fromTimestamp, toTimestamp) : null,
    ]);
    return { fromTimestamp, toTimestamp, ethUsdAtPost, opensea };
}

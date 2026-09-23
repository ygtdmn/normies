import "dotenv/config";

export const PORT = Number(process.env.PORT ?? 3000);

export const RPC_URLS: string[] = [
    process.env.RPC_URL,
    process.env.RPC_URL_FALLBACK_1,
    process.env.RPC_URL_FALLBACK_2,
].filter(Boolean) as string[];

// Contract addresses (Ethereum mainnet)
export const NORMIES_ADDRESS = "0x9Eb6E2025B64f340691e424b7fe7022fFDE12438" as const;
export const STORAGE_ADDRESS = "0x1B976bAf51cF51F0e369C070d47FBc47A706e602" as const;

// Canvas contract addresses (optional — if not set, canvas features are disabled)
export const CANVAS_ADDRESS = (process.env.CANVAS_ADDRESS ?? "0x64951d92e345C50381267380e2975f66810E869c") as `0x${string}` | undefined;
export const CANVAS_STORAGE_ADDRESS = (process.env.CANVAS_STORAGE_ADDRESS ?? "0xC255BE0983776BAB027a156681b6925cde47B2D1") as `0x${string}` | undefined;
export const CANVAS_ENABLED = !!(CANVAS_ADDRESS && CANVAS_STORAGE_ADDRESS);

// Zombie contract addresses (optional until deployed — if not set, zombie features are disabled)
export const ZOMBIE_ADDRESS = process.env.ZOMBIE_ADDRESS as `0x${string}` | undefined;
export const ZOMBIE_STORAGE_ADDRESS = process.env.ZOMBIE_STORAGE_ADDRESS as `0x${string}` | undefined;
export const ZOMBIE_RENDERER_ADDRESS = process.env.ZOMBIE_RENDERER_ADDRESS as `0x${string}` | undefined;
export const ZOMBIE_ENABLED = !!(ZOMBIE_ADDRESS && ZOMBIE_STORAGE_ADDRESS);
export const LEGENDARY_CANVAS_ADDRESS = process.env.LEGENDARY_CANVAS_ADDRESS as `0x${string}` | undefined;
export const LEGENDARY_CANVAS_ENABLED = !!LEGENDARY_CANVAS_ADDRESS;

// Pixel Market stack (set all three to enable /pixels, /market and grid-aware canvas status).
// Pixel balances live in NormiesCanvasStorageV2 next to the overlays.
export const CANVAS_V2_ADDRESS = process.env.CANVAS_V2_ADDRESS as `0x${string}` | undefined;
export const CANVAS_STORAGE_V2_ADDRESS = process.env.CANVAS_STORAGE_V2_ADDRESS as `0x${string}` | undefined;
export const MARKET_ADDRESS = process.env.MARKET_ADDRESS as `0x${string}` | undefined;
export const PIXEL_MARKET_ENABLED = !!(CANVAS_V2_ADDRESS && CANVAS_STORAGE_V2_ADDRESS && MARKET_ADDRESS);

// Revenue share (NormiesRevenuePool + NormiesRoyaltySplitter). Off when the pool address is unset.
export const REVENUE_POOL_ADDRESS = process.env.REVENUE_POOL_ADDRESS as `0x${string}` | undefined;
export const ROYALTY_SPLITTER_ADDRESS = process.env.ROYALTY_SPLITTER_ADDRESS as `0x${string}` | undefined;
export const REVSHARE_ENABLED = !!(PIXEL_MARKET_ENABLED && REVENUE_POOL_ADDRESS);
/** Where built epochs (payout tables and proofs) are written and served from. */
export const REVSHARE_DIR = process.env.REVSHARE_DIR ?? "data/revshare";
/** First block to scan for ledger BalanceMoved logs (the ledger's deploy block). */
export const REVSHARE_LEDGER_START_BLOCK = BigInt(process.env.REVSHARE_LEDGER_START_BLOCK ?? process.env.PIXEL_MARKET_START_BLOCK ?? 0);
export const MARKET_CACHE_TTL_MS = Number(process.env.MARKET_CACHE_TTL_MS ?? 10_000); // 10 seconds

// Cache settings
export const CACHE_MAX_ENTRIES = Number(process.env.CACHE_MAX_ENTRIES ?? 10_000);
export const CACHE_TTL_MS = Number(process.env.CACHE_TTL_MS ?? 3_600_000); // 1 hour default
export const CANVAS_CACHE_TTL_MS = Number(process.env.CANVAS_CACHE_TTL_MS ?? 60_000); // 1 minute
export const CANVAS_INFO_CACHE_TTL_MS = Number(process.env.CANVAS_INFO_CACHE_TTL_MS ?? 60_000); // 1 minute
export const CANVAS_STATUS_CACHE_TTL_MS = Number(process.env.CANVAS_STATUS_CACHE_TTL_MS ?? 300_000); // 5 minutes
export const ZOMBIE_CACHE_TTL_MS = Number(process.env.ZOMBIE_CACHE_TTL_MS ?? 60_000); // 1 minute
export const ZOMBIE_STATUS_CACHE_TTL_MS = Number(process.env.ZOMBIE_STATUS_CACHE_TTL_MS ?? 10_000); // 10 seconds
export const LEGENDARY_CANVAS_CACHE_TTL_MS = Number(process.env.LEGENDARY_CANVAS_CACHE_TTL_MS ?? 60_000); // 1 minute
export const RARITY_CACHE_TTL_MS = Number(process.env.RARITY_CACHE_TTL_MS ?? 60_000); // 1 minute
export const RARITY_LISTINGS_REFRESH_MS = Number(process.env.RARITY_LISTINGS_REFRESH_MS ?? 60_000); // 1 minute
// Consecutive refreshes a token must be absent from OpenSea before its listing is
// evicted. Debounces transient under-fetches (truncated pages / premature cursor
// end) that would otherwise flicker prices off and on. 3 -> absorbs up to 2
// consecutive bad cycles (~2 min) before trusting a removal.
export const LISTING_REMOVAL_GRACE = Math.max(1, Number(process.env.LISTING_REMOVAL_GRACE ?? 3));
export const OPENSEA_API_KEY = process.env.OPENSEA_API_KEY || undefined;
export const OPENSEA_COLLECTION_SLUG = process.env.OPENSEA_COLLECTION_SLUG || "normies";

// Rate limiting
export const RATE_LIMIT_WINDOW_MS = 60_000; // 1 minute
export const RATE_LIMIT_MAX_REQUESTS = Number(process.env.RATE_LIMIT_MAX ?? 60);

// Internal bypass secret (unset = bypass disabled)
export const INTERNAL_SECRET = process.env.INTERNAL_SECRET || undefined;

// Ponder indexer API (required for API server startup)
if (!process.env.PONDER_API_URL) {
    throw new Error("PONDER_API_URL must be configured");
}
export const PONDER_API_URL = process.env.PONDER_API_URL;
export const PONDER_API_SECRET = process.env.PONDER_API_SECRET || undefined;

// Chain we read against. Defaults to mainnet to match the hardcoded
// NORMIES_ADDRESS/STORAGE_ADDRESS above.
export const CHAIN_ID = Number(process.env.CHAIN_ID ?? 1);

// SVG constants (matching on-chain renderer exactly). GRID_SIZE is the base art
// grid; enlarged canvases (50..80) are inferred from bitmap length, see lib/bitmap.ts.
export const GRID_SIZE = 40;
export const SVG_OUTPUT_SIZE = 1000;
export const PNG_OUTPUT_SIZE = 1000;
export const BG_COLOR = "#e3e5e4";
export const PIXEL_COLOR = "#48494b";

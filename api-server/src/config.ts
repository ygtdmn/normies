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

// Cache settings
export const CACHE_MAX_ENTRIES = Number(process.env.CACHE_MAX_ENTRIES ?? 10_000);
export const CACHE_TTL_MS = Number(process.env.CACHE_TTL_MS ?? 3_600_000); // 1 hour default
export const CANVAS_CACHE_TTL_MS = Number(process.env.CANVAS_CACHE_TTL_MS ?? 60_000); // 1 minute
export const CANVAS_INFO_CACHE_TTL_MS = Number(process.env.CANVAS_INFO_CACHE_TTL_MS ?? 10_000); // 10 seconds

// Rate limiting
export const RATE_LIMIT_WINDOW_MS = 60_000; // 1 minute
export const RATE_LIMIT_MAX_REQUESTS = Number(process.env.RATE_LIMIT_MAX ?? 60);

// SVG constants (matching on-chain renderer exactly)
export const GRID_SIZE = 40;
export const SVG_OUTPUT_SIZE = 1000;
export const PNG_OUTPUT_SIZE = 1000;
export const BG_COLOR = "#e3e5e4";
export const PIXEL_COLOR = "#48494b";

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

// Cache settings
export const CACHE_MAX_ENTRIES = Number(process.env.CACHE_MAX_ENTRIES ?? 10_000);
export const CACHE_TTL_MS = Number(process.env.CACHE_TTL_MS ?? 3_600_000); // 1 hour default

// Rate limiting
export const RATE_LIMIT_WINDOW_MS = 60_000; // 1 minute
export const RATE_LIMIT_MAX_REQUESTS = Number(process.env.RATE_LIMIT_MAX ?? 60);

// SVG constants (matching on-chain renderer exactly)
export const GRID_SIZE = 40;
export const SVG_OUTPUT_SIZE = 1000;
export const PNG_OUTPUT_SIZE = 1000;
export const BG_COLOR = "#e3e5e4";
export const PIXEL_COLOR = "#48494b";

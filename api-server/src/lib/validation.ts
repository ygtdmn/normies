export function parseTokenId(idParam: string): { tokenId: number } | { error: string } {
    const parsed = Number(idParam);
    if (!Number.isInteger(parsed) || parsed < 0 || parsed >= 10_000) {
        return { error: `Invalid token ID: "${idParam}". Must be an integer 0-9999.` };
    }
    return { tokenId: parsed };
}

/**
 * A whole-number query parameter that never turns into a 500 (audit D-I1): missing, empty, non-numeric or
 * non-finite values fall back to the default; anything else is floored and clamped.
 */
export function queryInt(raw: string | undefined, fallback: number, min: number, max = Number.MAX_SAFE_INTEGER): number {
    const n = raw === undefined || raw.trim() === "" ? Number.NaN : Number(raw);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(Math.max(Math.floor(n), min), max);
}

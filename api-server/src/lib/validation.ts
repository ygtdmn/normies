export function parseTokenId(idParam: string): { tokenId: number } | { error: string } {
    const parsed = Number(idParam);
    if (!Number.isInteger(parsed) || parsed < 0 || parsed >= 10_000) {
        return { error: `Invalid token ID: "${idParam}". Must be an integer 0-9999.` };
    }
    return { tokenId: parsed };
}

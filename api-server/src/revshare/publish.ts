import type { EpochFile } from "./build.js";

/**
 * Where epoch files live for everyone to read. The job writes each file to REVSHARE_DIR/epochs on the indexer host,
 * Caddy serves that folder there at /revshare-epochs/ (behind the same Cloudflare rule as the indexer), and the API
 * fetches it with the indexer secret and serves it publicly at REVSHARE_PUBLIC_URL/<id>.json. That public URL is the
 * on-chain dataURI, so holders, the site and anyone verifying an epoch read the same file.
 */
export const DEFAULT_PUBLIC_URL = "https://api.normies.art/revshare/files";

export function publicBase(): string {
    return (process.env.REVSHARE_PUBLIC_URL?.trim() || DEFAULT_PUBLIC_URL).replace(/\/$/, "");
}

/** The public URL of an epoch file, which is also the dataURI posted on chain. */
export const epochUrl = (epochId: string | bigint) => `${publicBase()}/${epochId}.json`;

/**
 * Reads the file back through its public URL and checks it is this epoch. Posting waits on this, so a root never
 * goes on chain without a readable payout table behind it.
 */
export async function confirmPublished(epoch: EpochFile): Promise<string> {
    const url = epochUrl(epoch.epochId);
    // Up to 90 s: the API keeps a "not published" answer for a minute.
    for (let attempt = 1; attempt <= 30; attempt++) {
        const res = await fetch(`${url}?check=${Date.now()}`).catch(() => null);
        if (res?.ok) {
            const read = (await res.json().catch(() => null)) as EpochFile | null;
            if (read && read.root === epoch.root && read.epochId === epoch.epochId && read.total === epoch.total) return url;
        }
        await new Promise((r) => setTimeout(r, 3_000));
    }
    throw new Error(`${url} does not serve epoch ${epoch.epochId} (root ${epoch.root}); check REVSHARE_DIR, the Caddy path and the API`);
}

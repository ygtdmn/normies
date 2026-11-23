import { keccak256, toHex } from "viem";

/**
 * The revenue share scoring rules. One definition, used by the epoch builder, the API's live projection and (through
 * /revshare/config) the site. Everything is an integer so any implementation reproduces the same Merkle root.
 *
 *   score = (normiePoints + pixelPoints) x (100 + boostPct)
 *
 * Every pixel a wallet holds weighs the same: on a Normie, in the wallet balance, escrowed in a listing, or deposited
 * in the Normies Arena on one of its Normies (version 5). A wallet with no Normie scores zero, whatever it holds in
 * pixels (version 4).
 * Changing anything here changes `configHash`, which every posted epoch records on chain.
 */
export interface RevshareConfig {
    version: number;
    /** [minimum Normies held, whole-stack multiplier x100], ascending. */
    brackets: [number, number][];
    /** [minimum pixels in the wallet, boost percent], ascending. Needs at least one Normie. */
    boost: [number, number][];
    /** normiePoints = tokens x bracket100 x normieFactor; pixelPoints = pixels x pixelFactor. */
    normieFactor: number;
    pixelFactor: number;
    /** Sample blocks per UTC day, and how many trailing block hashes of each window seed the pick. */
    samplesPerDay: number;
    sampleEntropyBlocks: number;
    /** Addresses that never earn, on top of the protocol's own contracts. Lowercase. */
    excluded: string[];
    /**
     * NormiesArenaStorage (v3), lowercase. Since version 5 each live Normie's Arena balance counts for the Normie's
     * holder at the sample block: the balance follows the Normie and only its holder (or a delegate, paying the
     * holder) can withdraw it. Pixels a started round charged sit in the round's pool and belong to nobody until
     * prizes or refunds credit them back to a Normie. Sample blocks before the storage existed read nothing.
     * Absent in older configs, which never read the Arena, so posted epochs still rebuild the same.
     */
    arenaStorage?: string;
}

export const REVSHARE_CONFIG: RevshareConfig = {
    version: 5,
    brackets: [
        [1, 100],
        [2, 115],
        [5, 130],
        [10, 145],
        [25, 160],
        [50, 175],
    ],
    boost: [
        [15, 15],
        [100, 35],
        [500, 60],
        [1500, 100],
    ],
    // (tokens x bracket + pixels / 5) scaled by 1000: 1000 x bracket = 10 x bracket100, 1000 / 5 = 200 per pixel.
    normieFactor: 10,
    pixelFactor: 200,
    samplesPerDay: 4,
    sampleEntropyBlocks: 8,
    excluded: ["0x0000000000000000000000000000000000000000", "0x000000000000000000000000000000000000dead"],
    // Mainnet, deployed at block 26421432 (Arena v3 cutover, 15 Nov 2026).
    arenaStorage: "0x235403069c8516369eb36d29bb1a498a469ab9f0",
};

/** Keys sorted at every level, so the hash does not depend on how the object was written down. */
function canonical(value: unknown): string {
    if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
    if (value && typeof value === "object") {
        const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : 1));
        return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
    }
    return JSON.stringify(value);
}

export function configHash(config: RevshareConfig = REVSHARE_CONFIG): `0x${string}` {
    return keccak256(toHex(canonical(config)));
}

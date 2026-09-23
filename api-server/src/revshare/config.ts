import { keccak256, toHex } from "viem";

/**
 * The revenue share scoring rules. One definition, used by the epoch builder, the API's live projection and (through
 * /revshare/config) the site. Everything is an integer so any implementation reproduces the same Merkle root.
 *
 *   score = (normiePoints + pixelPoints) x (100 + boostPct)
 *
 * Every pixel a wallet holds weighs the same: on a Normie, in the wallet balance, or escrowed in a listing. A wallet
 * with no Normie scores zero, whatever it holds in pixels (version 4).
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
}

export const REVSHARE_CONFIG: RevshareConfig = {
    version: 4,
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

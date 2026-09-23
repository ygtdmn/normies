import { REVSHARE_CONFIG, type RevshareConfig } from "./config.js";

export interface WalletState {
    address: string;
    /** Live Normies the wallet owns. */
    tokens: number;
    /** Every pixel the wallet holds: on its Normies, in its balance, and escrowed in its active listings. */
    pixels: bigint;
}

export interface ScoreBreakdown {
    tokens: number;
    bracket100: number;
    pixels: bigint;
    boostPct: number;
    normiePoints: bigint;
    pixelPoints: bigint;
    score: bigint;
}

/** Whole-stack multiplier x100 for a wallet holding `tokens` Normies. */
export function bracket100(tokens: number, config: RevshareConfig = REVSHARE_CONFIG): number {
    let value = 0;
    for (const [min, x100] of config.brackets) if (tokens >= min) value = x100;
    return value;
}

/** Boost percent from the pixels the wallet holds. No Normie, no boost. */
export function boostPct(pixels: bigint, tokens: number, config: RevshareConfig = REVSHARE_CONFIG): number {
    if (tokens < 1) return 0;
    let value = 0;
    for (const [min, pct] of config.boost) if (pixels >= BigInt(min)) value = pct;
    return value;
}

/** A Normie is the membership: without one, the wallet's pixels earn nothing. */
export function scoreWallet(wallet: WalletState, config: RevshareConfig = REVSHARE_CONFIG): ScoreBreakdown {
    const { tokens, pixels } = wallet;
    const bracket = bracket100(tokens, config);
    const boost = boostPct(pixels, tokens, config);
    const normiePoints = BigInt(tokens) * BigInt(bracket) * BigInt(config.normieFactor);
    const pixelPoints = tokens < 1 ? 0n : pixels * BigInt(config.pixelFactor);
    const score = (normiePoints + pixelPoints) * BigInt(100 + boost);
    return { tokens, bracket100: bracket, pixels, boostPct: boost, normiePoints, pixelPoints, score };
}

import { REVSHARE_CONFIG, type RevshareConfig } from "./config.js";
import { scoreWallet, type WalletState } from "./score.js";

export interface Payout {
    account: `0x${string}`;
    amount: bigint;
}

/** address (lowercase) -> score for one sample. Excluded addresses and zero scores are left out. */
export function scoreSample(
    wallets: WalletState[],
    excluded: Set<string>,
    config: RevshareConfig = REVSHARE_CONFIG,
): Map<string, bigint> {
    const scores = new Map<string, bigint>();
    for (const wallet of wallets) {
        const address = wallet.address.toLowerCase();
        if (excluded.has(address)) continue;
        const { score } = scoreWallet(wallet, config);
        if (score > 0n) scores.set(address, score);
    }
    return scores;
}

/**
 * Time-weighting: the epoch amount is cut into equal slices, one per sample, and each slice is split by that
 * sample's scores. A wallet's payout is the sum of its floored shares, so holding through the whole epoch earns in
 * full and showing up for one sample earns one slice's worth. Samples nobody scored in are skipped. Rounding dust
 * (and skipped slices) stay in the pool for the next epoch; `total` is what the epoch actually allocates.
 */
export function buildPayouts(samples: Map<string, bigint>[], amount: bigint): { payouts: Payout[]; total: bigint } {
    const paid = new Map<string, bigint>();
    if (samples.length > 0) {
        const slice = amount / BigInt(samples.length);
        for (const scores of samples) {
            let totalScore = 0n;
            for (const score of scores.values()) totalScore += score;
            if (totalScore === 0n) continue;
            for (const [address, score] of scores) {
                const share = (slice * score) / totalScore;
                if (share > 0n) paid.set(address, (paid.get(address) ?? 0n) + share);
            }
        }
    }
    const payouts = [...paid.entries()]
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
        .map(([account, value]) => ({ account: account as `0x${string}`, amount: value }));
    const total = payouts.reduce((sum, p) => sum + p.amount, 0n);
    return { payouts, total };
}

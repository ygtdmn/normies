import type { EpochFile } from "./build.js";

/**
 * The checks that stand between a built epoch and postEpoch. A posted root pays out for good once its claims open
 * (POST_DELAY after posting, until when only a guardian can cancel it), so every rule here fails closed: a run that
 * cannot prove its epoch stops before posting.
 *
 * Kept free of RPC calls so each rule is unit-tested; cli.ts reads the chain and hands the values in.
 */

/** The second provider has to be configured and has to be a different endpoint, or "verified" means nothing. */
export function requireIndependentVerifier(primary: string | undefined, verifier: string | undefined): string {
    if (!verifier) throw new Error("RPC_URL_VERIFY is not set: an epoch is only posted after a second RPC rebuilds it");
    const norm = (url: string) => url.trim().replace(/\/+$/, "").toLowerCase();
    if (primary && norm(primary) === norm(verifier)) {
        throw new Error("RPC_URL_VERIFY is the same endpoint as RPC_URL; use an independent provider");
    }
    return verifier;
}

/**
 * Everything a second, independent rebuild must agree on. The amount is compared too: the second RPC computes the
 * pool's unreserved ETH at toBlock on its own instead of trusting the first one's number.
 */
export function epochMismatches(a: EpochFile, b: EpochFile): string[] {
    const out: string[] = [];
    const same = (field: string, x: unknown, y: unknown) => {
        if (String(x) !== String(y)) out.push(`${field}: ${String(x)} vs ${String(y)}`);
    };
    same("epochId", a.epochId, b.epochId);
    same("fromBlock", a.fromBlock, b.fromBlock);
    same("toBlock", a.toBlock, b.toBlock);
    same("chainId", a.chainId, b.chainId);
    same("amount", a.amount, b.amount);
    same("total", a.total, b.total);
    same("configHash", a.configHash, b.configHash);
    same("sampleBlocks", a.sampleBlocks.join(","), b.sampleBlocks.join(","));
    same("leaves", a.leaves.length, b.leaves.length);
    same("root", a.root, b.root);
    return out;
}

/** The newest epoch that is not cancelled, when its claims have not opened yet. */
export interface UnopenedEpoch {
    id: bigint;
    claimableAt: bigint;
}

/** What the pool says right before posting. Building takes hours, so this is read again at the last moment. */
export interface PoolState {
    nextEpochId: bigint;
    cursorToBlock: bigint;
    unallocated: bigint;
    paused: boolean;
    unopened: UnopenedEpoch | null;
}

/**
 * Reasons not to post `epoch` against the pool as it is now. The pool itself rejects a gap in block ranges or an
 * amount above what is unreserved; these catch the rest (an epoch id that moved on, which would make every leaf
 * unclaimable) and say plainly why, instead of a bare revert.
 */
export function prePostProblems(epoch: EpochFile, pool: PoolState): string[] {
    const out: string[] = [];
    if (pool.paused) out.push("the pool is paused for posting");
    // A cancel only hands back the latest range. With two unopened epochs, cancelling the older and then the newer
    // would leave the older range unpostable for good, so there is never more than one.
    if (pool.unopened) {
        out.push(
            `epoch ${pool.unopened.id} has not opened for claims yet (opens ${new Date(Number(pool.unopened.claimableAt) * 1000).toISOString()}); ` +
                "post after that, so there is never more than one epoch a cancel could still reach",
        );
    }
    if (BigInt(epoch.epochId) !== pool.nextEpochId) {
        out.push(`epoch id ${epoch.epochId} is not the pool's next id ${pool.nextEpochId}; every leaf would be unclaimable`);
    }
    if (pool.cursorToBlock !== 0n && BigInt(epoch.fromBlock) !== pool.cursorToBlock + 1n) {
        out.push(`epoch starts at block ${epoch.fromBlock} but the last posted epoch ended at ${pool.cursorToBlock}`);
    }
    if (BigInt(epoch.total) > pool.unallocated) {
        out.push(`epoch pays ${epoch.total} wei but the pool has only ${pool.unallocated} wei unreserved now`);
    }
    if (BigInt(epoch.total) > BigInt(epoch.amount)) out.push(`leaves add up to ${epoch.total}, more than the epoch amount ${epoch.amount}`);
    return out;
}

/** What the pool recorded for an epoch, read back after the post (or when verifying a posted epoch). */
export interface PostedEpoch {
    root: `0x${string}`;
    amount: bigint;
    fromBlock: bigint;
    toBlock: bigint;
}

export function postedMismatches(epoch: EpochFile, posted: PostedEpoch): string[] {
    const out: string[] = [];
    if (posted.root.toLowerCase() !== epoch.root.toLowerCase()) out.push(`root: file ${epoch.root}, pool ${posted.root}`);
    if (posted.amount !== BigInt(epoch.total)) out.push(`amount: file total ${epoch.total}, pool ${posted.amount}`);
    if (posted.fromBlock !== BigInt(epoch.fromBlock)) out.push(`fromBlock: file ${epoch.fromBlock}, pool ${posted.fromBlock}`);
    if (posted.toBlock !== BigInt(epoch.toBlock)) out.push(`toBlock: file ${epoch.toBlock}, pool ${posted.toBlock}`);
    return out;
}

/**
 * The last block an epoch may cover: never past the chain's finalized block, and never closer to the head than
 * `finality` blocks. `finalized` is null when the provider does not serve the finalized tag (a local fork).
 */
export function epochEndBlock(head: bigint, finalized: bigint | null, finality: bigint): bigint {
    const byDepth = head - finality;
    return finalized === null || finalized > byDepth ? byDepth : finalized;
}

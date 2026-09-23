import { type PublicClient, parseAbi } from "viem";
import { REVSHARE_CONFIG, configHash, type RevshareConfig } from "./config.js";
import { buildPayouts, scoreSample } from "./epoch.js";
import { buildTree, type EpochLeaf } from "./merkle.js";
import { pickSampleBlock, sampleWindows } from "./sample.js";
import { readState, type SnapshotAddresses } from "./snapshot.js";

export interface EpochAddresses extends SnapshotAddresses {
    canvasV2: `0x${string}`;
    pool: `0x${string}`;
    splitter?: `0x${string}`;
}

export interface EpochFile {
    epochId: string;
    fromBlock: string;
    toBlock: string;
    amount: string;
    total: string;
    root: `0x${string}`;
    configHash: `0x${string}`;
    config: RevshareConfig;
    chainId: number;
    addresses: Record<string, string>;
    excluded: string[];
    sampleBlocks: string[];
    leaves: EpochLeaf[];
}

const poolAbi = parseAbi([
    "function outstanding() view returns (uint256)",
    "function nextEpochId() view returns (uint256)",
]);

/** First block in [lo, hi] whose timestamp is >= `timestamp`, or hi + 1 if there is none. */
async function firstBlockAtOrAfter(client: PublicClient, timestamp: number, lo: bigint, hi: bigint): Promise<bigint> {
    let left = lo;
    let right = hi + 1n;
    while (left < right) {
        const mid = (left + right) / 2n;
        const block = await client.getBlock({ blockNumber: mid });
        if (Number(block.timestamp) >= timestamp) right = mid;
        else left = mid + 1n;
    }
    return left;
}

/** One unpredictable sample block per UTC window of the epoch. */
export async function sampleBlocks(
    client: PublicClient,
    fromBlock: bigint,
    toBlock: bigint,
    config: RevshareConfig,
): Promise<bigint[]> {
    const first = await client.getBlock({ blockNumber: fromBlock });
    const last = await client.getBlock({ blockNumber: toBlock });
    const windows = sampleWindows(Number(first.timestamp), Number(last.timestamp) + 1, config.samplesPerDay);
    const picks: bigint[] = [];
    for (const window of windows) {
        const start = await firstBlockAtOrAfter(client, window.start, fromBlock, toBlock);
        const end = (await firstBlockAtOrAfter(client, window.end, fromBlock, toBlock)) - 1n;
        if (end < start) continue; // no block fell inside this window
        const hashes: `0x${string}`[] = [];
        for (let n = end; n >= start && hashes.length < config.sampleEntropyBlocks; n -= 1n) {
            hashes.push((await client.getBlock({ blockNumber: n })).hash as `0x${string}`);
        }
        picks.push(pickSampleBlock(start, end, hashes));
    }
    return picks;
}

export async function exclusions(
    client: PublicClient,
    addresses: EpochAddresses,
    config: RevshareConfig,
    blockNumber: bigint,
): Promise<string[]> {
    const own = [addresses.market, addresses.pool, addresses.canvasV2, addresses.pixelStorage, addresses.splitter];
    return [...new Set([...config.excluded, ...own.filter(Boolean).map((a) => (a as string).toLowerCase())])].sort();
}

/**
 * Builds an epoch over [fromBlock, toBlock]. The amount defaults to what the pool held and had not yet promised at
 * toBlock, so money that arrives later belongs to the next epoch. `total` (the sum of the leaves) is what gets
 * posted; the difference is rounding dust that stays in the pool.
 */
export async function buildEpoch(
    client: PublicClient,
    addresses: EpochAddresses,
    options: { fromBlock: bigint; toBlock: bigint; epochId?: bigint; amount?: bigint; config?: RevshareConfig },
): Promise<EpochFile> {
    const config = options.config ?? REVSHARE_CONFIG;
    const { fromBlock, toBlock } = options;

    const epochId =
        options.epochId ?? (await client.readContract({ address: addresses.pool, abi: poolAbi, functionName: "nextEpochId" }));
    let amount = options.amount;
    if (amount === undefined) {
        const [balance, outstanding] = await Promise.all([
            client.getBalance({ address: addresses.pool, blockNumber: toBlock }),
            client.readContract({ address: addresses.pool, abi: poolAbi, functionName: "outstanding", blockNumber: toBlock }),
        ]);
        amount = balance - outstanding;
    }

    const excluded = await exclusions(client, addresses, config, toBlock);
    const excludedSet = new Set(excluded);
    const picks = await sampleBlocks(client, fromBlock, toBlock, config);
    const samples = [];
    for (const block of picks) samples.push(scoreSample(await readState(client, addresses, block), excludedSet, config));

    const { payouts, total } = buildPayouts(samples, amount);
    const { root, leaves } = buildTree(epochId, payouts);
    return {
        epochId: epochId.toString(),
        fromBlock: fromBlock.toString(),
        toBlock: toBlock.toString(),
        amount: amount.toString(),
        total: total.toString(),
        root,
        configHash: configHash(config),
        config,
        chainId: await client.getChainId(),
        addresses: Object.fromEntries(Object.entries(addresses).map(([k, v]) => [k, String(v)])),
        excluded,
        sampleBlocks: picks.map(String),
        leaves,
    };
}

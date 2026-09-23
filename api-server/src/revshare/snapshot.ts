import { type PublicClient, parseAbi } from "viem";
import type { WalletState } from "./score.js";

/**
 * The state the score reads, taken straight from an RPC node at one block: who holds which Normie, what is attached
 * to each, every wallet's balance, and what sellers have escrowed in active listings. Nothing comes from our
 * indexer, so anyone with an archive node gets the same answer.
 */
export interface SnapshotAddresses {
    normies: `0x${string}`;
    /** NormiesCanvasStorageV2: pixel balances live there next to the overlays. */
    pixelStorage: `0x${string}`;
    market: `0x${string}`;
}

export const TOTAL_TOKEN_IDS = 10_000;

const normiesAbi = parseAbi(["function ownerOf(uint256 tokenId) view returns (address)"]);
const pixelStorageAbi = parseAbi([
    "function attachedOf(uint256 tokenId) view returns (uint256)",
    "function balanceOf(address account) view returns (uint256)",
]);
const marketAbi = parseAbi([
    "struct Listing { address seller; uint64 expiry; bool partialFill; uint8 status; uint96 pricePerPixel; uint32 amount; uint32 remaining; }",
    "function nextListingId() view returns (uint256)",
    "function getListing(uint256 listingId) view returns (Listing)",
]);
const STATUS_ACTIVE = 1;

/** Calls per eth_call, and how many eth_calls are in flight at once. Small enough for a public archive node. */
const CALLS_PER_CHUNK = 400;
const CONCURRENCY = 3;

/**
 * viem's own batching fires every batch at once, which times out slow nodes (a fork, a rate limited archive RPC).
 * This sends fixed chunks with a small, steady concurrency and keeps results in call order.
 */
async function chunkedMulticall<T>(
    client: PublicClient,
    contracts: readonly unknown[],
    options: { blockNumber: bigint; allowFailure: boolean },
): Promise<T[]> {
    const chunks: unknown[][] = [];
    for (let i = 0; i < contracts.length; i += CALLS_PER_CHUNK) chunks.push(contracts.slice(i, i + CALLS_PER_CHUNK));
    const results: T[][] = new Array(chunks.length);
    let next = 0;
    const worker = async () => {
        while (next < chunks.length) {
            const at = next;
            next += 1;
            results[at] = (await client.multicall({
                blockNumber: options.blockNumber,
                allowFailure: options.allowFailure,
                batchSize: 0, // one eth_call per chunk
                contracts: chunks[at] as never,
            })) as T[];
        }
    };
    await Promise.all(Array.from({ length: Math.min(CONCURRENCY, chunks.length) }, worker));
    return results.flat();
}

export async function readState(
    client: PublicClient,
    addresses: SnapshotAddresses,
    blockNumber: bigint,
): Promise<WalletState[]> {
    const ids = Array.from({ length: TOTAL_TOKEN_IDS }, (_, i) => BigInt(i));

    // Burned ids revert on ownerOf, so failures are expected and simply mean "no such Normie at this block".
    const owners = await chunkedMulticall<{ status: "success" | "failure"; result?: unknown }>(
        client,
        ids.map((id) => ({ address: addresses.normies, abi: normiesAbi, functionName: "ownerOf", args: [id] })),
        { blockNumber, allowFailure: true },
    );
    const live: { tokenId: number; owner: string }[] = [];
    owners.forEach((r, i) => {
        if (r.status === "success") live.push({ tokenId: i, owner: (r.result as string).toLowerCase() });
    });

    const attached = await chunkedMulticall<bigint>(
        client,
        live.map(({ tokenId }) => ({ address: addresses.pixelStorage, abi: pixelStorageAbi, functionName: "attachedOf", args: [BigInt(tokenId)] })),
        { blockNumber, allowFailure: false },
    );

    const wallets = new Map<string, WalletState>();
    const wallet = (address: string) => {
        let w = wallets.get(address);
        if (!w) {
            w = { address, tokens: 0, pixels: 0n };
            wallets.set(address, w);
        }
        return w;
    };
    live.forEach(({ owner }, i) => {
        const w = wallet(owner);
        w.tokens += 1;
        w.pixels += attached[i];
    });

    // Wallet balances of every Normie holder. A wallet without a Normie scores zero, so nobody else is read.
    const holders = [...wallets.keys()];
    const balances = await chunkedMulticall<bigint>(
        client,
        holders.map((account) => ({ address: addresses.pixelStorage, abi: pixelStorageAbi, functionName: "balanceOf", args: [account] })),
        { blockNumber, allowFailure: false },
    );
    holders.forEach((account, i) => {
        const balance = balances[i];
        if (balance > 0n) wallet(account).pixels += balance;
    });

    // Pixels escrowed in an active listing still belong to the seller. The market's own balance is excluded later.
    const nextListingId = await client.readContract({
        address: addresses.market,
        abi: marketAbi,
        functionName: "nextListingId",
        blockNumber,
    });
    if (nextListingId > 1n) {
        const listingIds = Array.from({ length: Number(nextListingId - 1n) }, (_, i) => BigInt(i + 1));
        const listings = await chunkedMulticall<{ seller: string; status: number; remaining: number }>(
            client,
            listingIds.map((id) => ({ address: addresses.market, abi: marketAbi, functionName: "getListing", args: [id] })),
            { blockNumber, allowFailure: false },
        );
        for (const l of listings) {
            if (l.status === STATUS_ACTIVE && l.remaining > 0) wallet(l.seller.toLowerCase()).pixels += BigInt(l.remaining);
        }
    }

    return [...wallets.values()].sort((a, b) => (a.address < b.address ? -1 : 1));
}

import "dotenv/config";
import { createPublicClient, createWalletClient, http, parseAbi, parseAbiItem, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry, mainnet, sepolia } from "viem/chains";

/**
 * Copies every delegation from the original canvas into NormiesCanvasStorageV2 and seals the copy, in ONE
 * transaction (`seedAndFinalizeDelegations`). The Solidity version of this read 10,000 ids through the fork
 * backend and took minutes; this one takes seconds: the ids come from V1's own `DelegateSet` events (the only
 * thing that ever writes `delegates[id]`), and their current delegate and setter are read at one snapshot block
 * with multicall. Later V1 changes are deliberately ignored: the snapshot block and time go on chain with the copy.
 *
 *   pnpm cutover:delegations [--block <n>] [--dry-run]
 *
 * Env: RPC_URL, CHAIN_ID (1, 11155111, 31337), CANVAS_STORAGE_V2_ADDRESS, CANVAS_V1_DEPLOY_BLOCK (24534798 by
 * default), and either PRIVATE_KEY (the storage owner) or FROM (an unlocked account on anvil). Refuses unless the
 * balance migration is finalized, the delegation copy is still open and V1 is paused.
 */
const RPC_URL = process.env.RPC_URL;
const CHAIN_ID = Number(process.env.CHAIN_ID ?? 1);
const V1_DEPLOY_BLOCK = BigInt(process.env.CANVAS_V1_DEPLOY_BLOCK ?? 24_534_798);
const anvilFork = {
    ...foundry,
    contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" as const } },
};
const chain = CHAIN_ID === 1 ? mainnet : CHAIN_ID === 31_337 ? anvilFork : sepolia;

const storageAbi = parseAbi([
    "function legacyCanvas() view returns (address)",
    "function delegationsSeeded() view returns (bool)",
    "function migrationFinalized() view returns (bool)",
    "function delegates(uint256) view returns (address)",
    "function delegateSetBy(uint256) view returns (address)",
    "function seedAndFinalizeDelegations(uint256[] tokenIds, address[] delegates, address[] setBy, uint256 snapshotBlock, uint256 snapshotTimestamp)",
]);
const v1Abi = parseAbi([
    "function paused() view returns (bool)",
    "function delegates(uint256) view returns (address)",
    "function delegateSetBy(uint256) view returns (address)",
]);
const delegateSet = parseAbiItem("event DelegateSet(uint256 indexed tokenId, address indexed delegate)");
const ZERO = "0x0000000000000000000000000000000000000000";

function env(name: string): `0x${string}` {
    const value = process.env[name];
    if (!value) throw new Error(`${name} is not set`);
    return value as `0x${string}`;
}

function flag(name: string): string | undefined {
    const at = process.argv.indexOf(`--${name}`);
    return at === -1 ? undefined : process.argv[at + 1];
}

async function main() {
    if (!RPC_URL) throw new Error("RPC_URL is not set");
    const dryRun = process.argv.includes("--dry-run");
    const client = createPublicClient({ chain, transport: http(RPC_URL, { timeout: 120_000, retryCount: 3 }) });
    const storage = env("CANVAS_STORAGE_V2_ADDRESS");

    const [v1, seeded, migrated] = await Promise.all([
        client.readContract({ address: storage, abi: storageAbi, functionName: "legacyCanvas" }),
        client.readContract({ address: storage, abi: storageAbi, functionName: "delegationsSeeded" }),
        client.readContract({ address: storage, abi: storageAbi, functionName: "migrationFinalized" }),
    ]);
    if (seeded) throw new Error("delegations are already finalized on this storage");
    if (!migrated) throw new Error("finalize the balance migration first (MigrateLegacy.s.sol)");
    const paused = await client.readContract({ address: v1, abi: v1Abi, functionName: "paused" });
    if (!paused) throw new Error("pause the original canvas before migrating delegations");

    const snapshotBlock = flag("block") ? BigInt(flag("block")!) : await client.getBlockNumber();
    const { timestamp } = await client.getBlock({ blockNumber: snapshotBlock });

    // Every token that ever had a delegate; revoked ones read back as the zero address and are dropped.
    const ids = new Set<bigint>();
    const step = 200_000n;
    for (let from = V1_DEPLOY_BLOCK; from <= snapshotBlock; from += step) {
        const to = from + step - 1n < snapshotBlock ? from + step - 1n : snapshotBlock;
        const logs = await client.getLogs({ address: v1, event: delegateSet, fromBlock: from, toBlock: to });
        for (const log of logs) ids.add(log.args.tokenId!);
    }
    const candidates = [...ids].sort((a, b) => (a < b ? -1 : 1));

    const tokenIds: bigint[] = [];
    const delegates: Address[] = [];
    const setBy: Address[] = [];
    for (let i = 0; i < candidates.length; i += 500) {
        const chunk = candidates.slice(i, i + 500);
        const results = await client.multicall({
            blockNumber: snapshotBlock,
            allowFailure: false,
            contracts: chunk.flatMap((id) => [
                { address: v1, abi: v1Abi, functionName: "delegates", args: [id] } as const,
                { address: v1, abi: v1Abi, functionName: "delegateSetBy", args: [id] } as const,
            ]),
        });
        chunk.forEach((id, k) => {
            const delegate = results[2 * k] as Address;
            if (delegate === ZERO) return;
            tokenIds.push(id);
            delegates.push(delegate);
            setBy.push(results[2 * k + 1] as Address);
        });
    }
    console.log(
        `snapshot block ${snapshotBlock} (${new Date(Number(timestamp) * 1000).toISOString()}): ${candidates.length} tokens ever delegated, ${tokenIds.length} delegations to copy`,
    );
    if (dryRun) {
        tokenIds.forEach((id, i) => console.log(`  #${id} -> ${delegates[i]} (set by ${setBy[i]})`));
        return;
    }

    const account = process.env.PRIVATE_KEY ? privateKeyToAccount(process.env.PRIVATE_KEY as Hex) : env("FROM");
    const wallet = createWalletClient({ account, chain, transport: http(RPC_URL, { timeout: 120_000 }) });
    const hash = await wallet.writeContract({
        address: storage,
        abi: storageAbi,
        functionName: "seedAndFinalizeDelegations",
        args: [tokenIds, delegates, setBy, snapshotBlock, timestamp],
    });
    console.log(`seedAndFinalizeDelegations sent: ${hash}`);
    const receipt = await client.waitForTransactionReceipt({ hash, timeout: 600_000 });
    if (receipt.status !== "success") throw new Error(`transaction reverted: ${hash}`);

    const sealed = await client.readContract({ address: storage, abi: storageAbi, functionName: "delegationsSeeded" });
    if (!sealed) throw new Error("transaction mined but delegationsSeeded() is still false");
    if (tokenIds.length > 0) {
        const check = await client.readContract({ address: storage, abi: storageAbi, functionName: "delegates", args: [tokenIds[0]] });
        if (check.toLowerCase() !== delegates[0].toLowerCase()) throw new Error(`spot check failed on #${tokenIds[0]}`);
    }
    console.log(`delegations sealed in block ${receipt.blockNumber}, ${receipt.gasUsed} gas, ${tokenIds.length} records`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});

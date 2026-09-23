import "dotenv/config";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createPublicClient, createWalletClient, http, parseAbi, type Hex, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry, mainnet, sepolia } from "viem/chains";
import { buildEpoch, type EpochAddresses, type EpochFile } from "./build.js";

/**
 * Revenue share epochs from the command line.
 *
 *   pnpm revshare build --from <block> --to <block> [--epoch <id>] [--amount <wei>]
 *   pnpm revshare verify <epoch.json>
 *   pnpm revshare run [--dry-run]
 *
 * `run` is the whole monthly job in one command, for the systemd timer in deploy/revshare: it releases the
 * splitter and unwraps the pool so the epoch holds everything earned, picks the block range (from the last
 * epoch's end, to a finalized head), builds the epoch, verifies it against a second RPC when RPC_URL_VERIFY
 * is set, writes the file where the API serves it, and posts the root from the owner key. It refuses to post
 * an epoch shorter than MIN_EPOCH_BLOCKS, so a double run is harmless.
 *
 * `build` writes <REVSHARE_DIR>/epochs/<id>.json and prints the postEpoch call. Before picking --to, run the
 * splitter's release() and the pool's unwrap() so the epoch holds everything earned in
 * it. `verify` recomputes an epoch file from chain state and fails loudly if the root differs; it needs an archive
 * node and nothing else.
 */
/**
 * Env: RPC_URL (an archive node), CHAIN_ID (1, 11155111 or 31337), NORMIES_ADDRESS (mainnet Normies by default),
 * CANVAS_STORAGE_V2_ADDRESS, MARKET_ADDRESS, CANVAS_V2_ADDRESS, REVENUE_POOL_ADDRESS, optional ROYALTY_SPLITTER_ADDRESS
 * and REVSHARE_DIR (data/revshare by default). `run` also needs PRIVATE_KEY (the pool owner; or FROM, an unlocked
 * account on anvil) and takes RPC_URL_VERIFY, EPOCH_FINALITY_BLOCKS (64), MIN_EPOCH_BLOCKS (7000, about a day),
 * REVSHARE_GENESIS_BLOCK (the first epoch's start; PIXEL_MARKET_START_BLOCK is also accepted) and
 * REVSHARE_PUBLIC_URL (https://api.normies.art/revshare/epochs), which becomes the on-chain dataURI.
 */
const RPC_URL = process.env.RPC_URL;
const CHAIN_ID = Number(process.env.CHAIN_ID ?? 1);
const REVSHARE_DIR = process.env.REVSHARE_DIR ?? "data/revshare";

// A local Anvil mainnet fork carries mainnet's Multicall3, but viem's foundry chain definition does not list it.
const anvilFork = {
    ...foundry,
    contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" as const } },
};

// A snapshot is tens of thousands of historical reads, so the client is patient.
const chain = CHAIN_ID === 1 ? mainnet : CHAIN_ID === 31_337 ? anvilFork : sepolia;
const publicClient = createPublicClient({
    chain,
    transport: http(RPC_URL, { timeout: 600_000, retryCount: 3, retryDelay: 2_000 }),
}) as PublicClient;

function env(name: string): `0x${string}` {
    const value = process.env[name];
    if (!value) throw new Error(`${name} is not set`);
    return value as `0x${string}`;
}

function addresses(): EpochAddresses {
    if (!RPC_URL) throw new Error("RPC_URL is not set");
    return {
        normies: (process.env.NORMIES_ADDRESS as `0x${string}` | undefined) ?? "0x9Eb6E2025B64f340691e424b7fe7022fFDE12438",
        pixelStorage: env("CANVAS_STORAGE_V2_ADDRESS"),
        market: env("MARKET_ADDRESS"),
        canvasV2: env("CANVAS_V2_ADDRESS"),
        pool: env("REVENUE_POOL_ADDRESS"),
        splitter: process.env.ROYALTY_SPLITTER_ADDRESS as `0x${string}` | undefined,
    };
}

function flag(args: string[], name: string): string | undefined {
    const at = args.indexOf(`--${name}`);
    return at === -1 ? undefined : args[at + 1];
}

const opsAbi = parseAbi([
    "function nextEpochId() view returns (uint256)",
    "function getEpoch(uint256) view returns ((bytes32 root, uint128 amount, uint128 claimed, uint64 claimableAt, uint64 sweepableAt, uint64 fromBlock, uint64 toBlock, uint8 status))",
    "function weth() view returns (address)",
    "function unwrap()",
    "function release()",
    "function postEpoch(bytes32 root, uint256 amount, uint64 fromBlock, uint64 toBlock, bytes32 configHash, string dataURI) returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
]);

function writeEpochFile(epoch: EpochFile): string {
    const dir = join(REVSHARE_DIR, "epochs");
    mkdirSync(dir, { recursive: true });
    const path = join(dir, `${epoch.epochId}.json`);
    writeFileSync(path, `${JSON.stringify(epoch, null, 2)}\n`);
    return path;
}

/** The monthly job. Every step is idempotent and the run stops at the first thing that is not right. */
async function runEpoch(dryRun: boolean) {
    const a = addresses();
    const finality = BigInt(process.env.EPOCH_FINALITY_BLOCKS ?? 64);
    const minBlocks = BigInt(process.env.MIN_EPOCH_BLOCKS ?? 7000);
    const publicUrl = (process.env.REVSHARE_PUBLIC_URL ?? "https://api.normies.art/revshare/epochs").replace(/\/$/, "");
    const account = process.env.PRIVATE_KEY
        ? privateKeyToAccount(process.env.PRIVATE_KEY as Hex)
        : (process.env.FROM as `0x${string}` | undefined);
    if (!account && !dryRun) throw new Error("PRIVATE_KEY (or FROM on anvil) is not set");
    const wallet = account ? createWalletClient({ account, chain, transport: http(RPC_URL, { timeout: 120_000 }) }) : null;

    // 1. Where the last epoch ended.
    const nextEpochId = await publicClient.readContract({ address: a.pool, abi: opsAbi, functionName: "nextEpochId" });
    let fromBlock: bigint;
    if (nextEpochId > 1n) {
        const last = await publicClient.readContract({ address: a.pool, abi: opsAbi, functionName: "getEpoch", args: [nextEpochId - 1n] });
        fromBlock = BigInt(last.toBlock) + 1n;
    } else {
        const genesis = process.env.REVSHARE_GENESIS_BLOCK ?? process.env.PIXEL_MARKET_START_BLOCK;
        if (!genesis) throw new Error("first epoch: set REVSHARE_GENESIS_BLOCK");
        fromBlock = BigInt(genesis);
    }

    // 2. Sweep royalties and WETH into the pool so the epoch holds everything earned so far. Both are
    //    permissionless; skipped when there is nothing to move.
    let settledAt = 0n;
    if (wallet && !dryRun) {
        const weth = await publicClient.readContract({ address: a.pool, abi: opsAbi, functionName: "weth" });
        if (a.splitter) {
            const [eth, wrapped] = await Promise.all([
                publicClient.getBalance({ address: a.splitter }),
                publicClient.readContract({ address: weth, abi: opsAbi, functionName: "balanceOf", args: [a.splitter] }),
            ]);
            if (eth + wrapped > 0n) {
                const hash = await wallet.writeContract({ address: a.splitter, abi: opsAbi, functionName: "release" });
                const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 600_000 });
                if (r.status !== "success") throw new Error(`release() reverted: ${hash}`);
                settledAt = r.blockNumber;
                console.log(`splitter released ${eth + wrapped} wei in block ${r.blockNumber}`);
            }
        }
        const poolWeth = await publicClient.readContract({ address: weth, abi: opsAbi, functionName: "balanceOf", args: [a.pool] });
        if (poolWeth > 0n) {
            const hash = await wallet.writeContract({ address: a.pool, abi: opsAbi, functionName: "unwrap" });
            const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 600_000 });
            if (r.status !== "success") throw new Error(`unwrap() reverted: ${hash}`);
            settledAt = r.blockNumber;
            console.log(`pool unwrapped ${poolWeth} wei of WETH in block ${r.blockNumber}`);
        }
    }

    // 3. The epoch ends at a finalized block that already includes those transfers.
    let head = await publicClient.getBlockNumber();
    while (settledAt > 0n && head < settledAt + finality) {
        await new Promise((r) => setTimeout(r, 15_000));
        head = await publicClient.getBlockNumber();
    }
    const toBlock = head - finality;
    if (toBlock < fromBlock + minBlocks - 1n) {
        console.log(`epoch ${nextEpochId} would cover only ${toBlock - fromBlock + 1n} blocks (from ${fromBlock} to ${toBlock}); nothing to post yet`);
        return;
    }

    // 4. Build, save, verify. A pool with nothing unreserved has nothing to distribute; that is not an error.
    const [poolBalance, outstanding] = await Promise.all([
        publicClient.getBalance({ address: a.pool, blockNumber: toBlock }),
        publicClient.readContract({ address: a.pool, abi: parseAbi(["function outstanding() view returns (uint256)"]), functionName: "outstanding", blockNumber: toBlock }),
    ]);
    if (poolBalance <= outstanding) {
        console.log(`epoch ${nextEpochId}: the pool holds nothing unreserved at block ${toBlock}; nothing to post`);
        return;
    }
    const epoch = await buildEpoch(publicClient, a, { fromBlock, toBlock, epochId: nextEpochId });
    const path = writeEpochFile(epoch);
    console.log(`epoch ${epoch.epochId}: blocks ${fromBlock}..${toBlock}, ${epoch.leaves.length} payouts, ${epoch.total} wei of ${epoch.amount} -> ${path}`);
    if (BigInt(epoch.total) === 0n) {
        console.log("nothing to pay out; not posting");
        return;
    }
    if (process.env.RPC_URL_VERIFY) {
        const second = createPublicClient({
            chain,
            transport: http(process.env.RPC_URL_VERIFY, { timeout: 600_000, retryCount: 3, retryDelay: 2_000 }),
        }) as PublicClient;
        const again = await buildEpoch(second, a, { fromBlock, toBlock, epochId: nextEpochId, amount: BigInt(epoch.amount), config: epoch.config });
        if (again.root !== epoch.root || again.total !== epoch.total) {
            throw new Error(`verification mismatch: ${epoch.root} (${epoch.total}) vs ${again.root} (${again.total}); not posting`);
        }
        console.log("verified against the second RPC");
    }
    if (dryRun || !wallet) {
        console.log(`dry run: would post root ${epoch.root} for ${epoch.total} wei`);
        return;
    }

    // 5. Post. Claims open in the same block.
    const dataURI = `${publicUrl}/${epoch.epochId}`;
    const hash = await wallet.writeContract({
        address: a.pool,
        abi: opsAbi,
        functionName: "postEpoch",
        args: [epoch.root, BigInt(epoch.total), BigInt(epoch.fromBlock), BigInt(epoch.toBlock), epoch.configHash, dataURI],
    });
    const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 600_000 });
    if (r.status !== "success") throw new Error(`postEpoch reverted: ${hash}`);
    console.log(`epoch ${epoch.epochId} posted in block ${r.blockNumber}: ${hash}`);
}

async function main() {
    const [command, ...args] = process.argv.slice(2);

    if (command === "build") {
        const from = flag(args, "from");
        const to = flag(args, "to");
        if (!from || !to) throw new Error("build needs --from and --to");
        const epoch = await buildEpoch(publicClient, addresses(), {
            fromBlock: BigInt(from),
            toBlock: BigInt(to),
            epochId: flag(args, "epoch") ? BigInt(flag(args, "epoch")!) : undefined,
            amount: flag(args, "amount") ? BigInt(flag(args, "amount")!) : undefined,
        });
        const path = writeEpochFile(epoch);
        console.log(`epoch ${epoch.epochId}: ${epoch.leaves.length} payouts, ${epoch.total} wei of ${epoch.amount} -> ${path}`);
        console.log(`samples: ${epoch.sampleBlocks.join(", ")}`);
        console.log(
            `post: cast send ${epoch.addresses.pool} "postEpoch(bytes32,uint256,uint64,uint64,bytes32,string)" ${epoch.root} ${epoch.total} ${epoch.fromBlock} ${epoch.toBlock} ${epoch.configHash} "<dataURI>"`,
        );
        return;
    }

    if (command === "verify") {
        const path = args[0];
        if (!path) throw new Error("verify needs a path to an epoch file");
        const file = JSON.parse(readFileSync(path, "utf8")) as EpochFile;
        const rebuilt = await buildEpoch(publicClient, addresses(), {
            fromBlock: BigInt(file.fromBlock),
            toBlock: BigInt(file.toBlock),
            epochId: BigInt(file.epochId),
            amount: BigInt(file.amount),
            config: file.config,
        });
        if (rebuilt.root !== file.root || rebuilt.total !== file.total) {
            console.error(`MISMATCH epoch ${file.epochId}: file ${file.root} (${file.total}), chain ${rebuilt.root} (${rebuilt.total})`);
            process.exit(1);
        }
        console.log(`epoch ${file.epochId} verified: ${file.root}`);
        return;
    }

    if (command === "run") {
        await runEpoch(args.includes("--dry-run"));
        return;
    }

    console.error("usage: revshare build --from <block> --to <block> [--epoch <id>] [--amount <wei>] | verify <epoch.json> | run [--dry-run]");
    process.exit(1);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});

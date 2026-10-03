import "dotenv/config";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createPublicClient, createWalletClient, http, parseAbi, type Hex, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry, mainnet, sepolia } from "viem/chains";
import { buildEpoch, type EpochAddresses, type EpochFile } from "./build.js";
import { safeBatch } from "./proposal.js";
import {
    epochEndBlock,
    epochMismatches,
    postedMismatches,
    prePostProblems,
    requireIndependentVerifier,
    type PoolState,
} from "./guards.js";

/**
 * Revenue share epochs from the command line.
 *
 *   pnpm revshare build --epoch <id> --from <block> --to <block> [--amount <wei>]
 *   pnpm revshare verify <epoch.json>
 *   pnpm revshare run [--dry-run]
 *
 * A posted root opens for claims POST_DELAY (24 hours) later and pays out for good from then on; only a guardian can
 * cancel it before that. So posting follows one fixed order and stops at the first thing that is not right: release the splitter, unwrap the pool, wait until those transfers
 * are finalized, build, rebuild on a second independent RPC and compare everything, re-read the pool, post, and
 * read the posted epoch back. The rules live in guards.ts.
 *
 * `run` is that whole sequence, for the systemd timer in deploy/revshare. It refuses to post an epoch shorter
 * than MIN_EPOCH_BLOCKS, so a double run is harmless, and it never posts without RPC_URL_VERIFY.
 *
 * No owner key on the server: the job's PRIVATE_KEY holds the pool's POSTER role and nothing else.
 * It posts directly; claims open POST_DELAY (24 h) later, and until then the Operations Safe can cancel a bad
 * epoch with cancelEpoch. A key without the role (or the owner, on a local fork, which may post too) falls back to
 * writing <REVSHARE_DIR>/proposals/<id>.safe.json, a Safe Transaction Builder batch for the pool owner, and stops;
 * until the pool shows that epoch posted, later runs leave the proposal and its epoch file alone.
 *
 * `build` and `verify` are the manual path. `build` needs the epoch id explicitly (the pool's next id can move
 * while a build runs) and writes <REVSHARE_DIR>/epochs/<id>.json. `verify` rebuilds a file from chain state,
 * amount included, and then checks it against the pool: a posted epoch must match what the pool recorded, an
 * unposted one must be postable right now. Run it on an RPC other than the one that built the file, before
 * anyone sends the postEpoch call.
 */
/**
 * Env: RPC_URL (an archive node), CHAIN_ID (1, 11155111 or 31337), NORMIES_ADDRESS (mainnet Normies by default),
 * CANVAS_STORAGE_V2_ADDRESS, MARKET_ADDRESS, CANVAS_V2_ADDRESS, REVENUE_POOL_ADDRESS, optional ROYALTY_SPLITTER_ADDRESS
 * and REVSHARE_DIR (data/revshare by default). `run` also needs PRIVATE_KEY (a key holding the pool's POSTER role, or
 * any key, which then writes a Safe proposal instead; or FROM, an unlocked account on anvil) and takes RPC_URL_VERIFY, EPOCH_FINALITY_BLOCKS (64), MIN_EPOCH_BLOCKS (7000, about a day),
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
    "function cursorToBlock() view returns (uint64)",
    "function unallocated() view returns (uint256)",
    "function paused() view returns (bool)",
    "function outstanding() view returns (uint256)",
    "function owner() view returns (address)",
    "function hasAnyRole(address user, uint256 roles) view returns (bool)",
]);

/** NormiesAccess role bits. POSTER may call postEpoch and nothing else. */
const POSTER_ROLE = 1n << 2n;
const STATUS_CANCELLED = 3;

const proposalPath = (epochId: string | bigint) => join(REVSHARE_DIR, "proposals", `${epochId}.safe.json`);

/** Writes the Safe Transaction Builder batch for `epoch` next to the epoch files (not served by the API). */
function writeProposal(epoch: EpochFile, pool: `0x${string}`, safe: `0x${string}`, dataURI: string, chainId: number): string {
    mkdirSync(join(REVSHARE_DIR, "proposals"), { recursive: true });
    const path = proposalPath(epoch.epochId);
    writeFileSync(path, `${JSON.stringify(safeBatch(epoch, pool, safe, dataURI, chainId), null, 2)}\n`);
    return path;
}

function makeClient(url: string): PublicClient {
    return createPublicClient({ chain, transport: http(url, { timeout: 600_000, retryCount: 3, retryDelay: 2_000 }) }) as PublicClient;
}

async function poolState(client: PublicClient, pool: `0x${string}`): Promise<PoolState> {
    const [nextEpochId, cursorToBlock, unallocated, paused] = await Promise.all([
        client.readContract({ address: pool, abi: opsAbi, functionName: "nextEpochId" }),
        client.readContract({ address: pool, abi: opsAbi, functionName: "cursorToBlock" }),
        client.readContract({ address: pool, abi: opsAbi, functionName: "unallocated" }),
        client.readContract({ address: pool, abi: opsAbi, functionName: "paused" }),
    ]);
    return { nextEpochId, cursorToBlock: BigInt(cursorToBlock), unallocated, paused };
}

/** The chain's finalized block, or null when the provider does not serve the tag (a local fork). */
async function finalizedBlock(client: PublicClient): Promise<bigint | null> {
    try {
        return (await client.getBlock({ blockTag: "finalized" })).number;
    } catch {
        return null;
    }
}

/** Both providers must be on the same chain and agree on the epoch's last block, or a rebuild proves nothing. */
async function sameChainAt(first: PublicClient, second: PublicClient, block: bigint) {
    const [idA, idB, a, b] = await Promise.all([
        first.getChainId(),
        second.getChainId(),
        first.getBlock({ blockNumber: block }),
        second.getBlock({ blockNumber: block }),
    ]);
    if (idA !== idB) throw new Error(`the two RPCs are on different chains (${idA} vs ${idB})`);
    if (a.hash !== b.hash) throw new Error(`the two RPCs disagree on block ${block}: ${a.hash} vs ${b.hash}`);
}

function fail(problems: string[], what: string): void {
    if (problems.length === 0) return;
    throw new Error(`${what}:\n  - ${problems.join("\n  - ")}`);
}

function writeEpochFile(epoch: EpochFile): string {
    const dir = join(REVSHARE_DIR, "epochs");
    mkdirSync(dir, { recursive: true });
    const path = join(dir, `${epoch.epochId}.json`);
    writeFileSync(path, `${JSON.stringify(epoch, null, 2)}\n`);
    return path;
}

/** The monthly job. Every step is idempotent and the run stops at the first thing that is not right. */
async function runEpoch(dryRun: boolean, replaceProposal: boolean) {
    const a = addresses();
    const finality = BigInt(process.env.EPOCH_FINALITY_BLOCKS ?? 64);
    const minBlocks = BigInt(process.env.MIN_EPOCH_BLOCKS ?? 7000);
    const publicUrl = (process.env.REVSHARE_PUBLIC_URL ?? "https://api.normies.art/revshare/epochs").replace(/\/$/, "");
    const account = process.env.PRIVATE_KEY
        ? privateKeyToAccount(process.env.PRIVATE_KEY as Hex)
        : (process.env.FROM as `0x${string}` | undefined);
    if (!account && !dryRun) throw new Error("PRIVATE_KEY (or FROM on anvil) is not set");
    // Checked before anything is sent, so a misconfigured job does not even release or unwrap.
    const verifierUrl = dryRun && !process.env.RPC_URL_VERIFY ? null : requireIndependentVerifier(RPC_URL, process.env.RPC_URL_VERIFY);
    if (!verifierUrl) console.log("dry run without RPC_URL_VERIFY: the second-RPC rebuild is skipped; a real run refuses");
    const wallet = account ? createWalletClient({ account, chain, transport: http(RPC_URL, { timeout: 120_000 }) }) : null;

    // 1. Where the last epoch ended.
    const nextEpochId = await publicClient.readContract({ address: a.pool, abi: opsAbi, functionName: "nextEpochId" });
    // An epoch proposed to the Safe and not yet posted: its file is what the signers are checking, so leave it be.
    if (existsSync(proposalPath(nextEpochId)) && !replaceProposal) {
        console.log(`epoch ${nextEpochId} is waiting for the pool owner to execute ${proposalPath(nextEpochId)}; nothing to do`);
        console.log("(rerun with --replace-proposal to rebuild it, then delete the old transaction from the Safe queue)");
        return;
    }
    // The pool's cursor, not the last epoch's range: a cancelled epoch hands its range back to be posted again.
    const cursor = BigInt(await publicClient.readContract({ address: a.pool, abi: opsAbi, functionName: "cursorToBlock" }));
    let fromBlock: bigint;
    if (cursor > 0n) {
        fromBlock = cursor + 1n;
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

    // 3. The epoch ends at a finalized block (and at least EPOCH_FINALITY_BLOCKS deep) that already includes those
    //    transfers, so neither a reorg nor a late transfer can change what it covers.
    let toBlock = epochEndBlock(await publicClient.getBlockNumber(), await finalizedBlock(publicClient), finality);
    while (settledAt > 0n && toBlock < settledAt) {
        await new Promise((r) => setTimeout(r, 15_000));
        toBlock = epochEndBlock(await publicClient.getBlockNumber(), await finalizedBlock(publicClient), finality);
    }
    if (settledAt > 0n) console.log(`release/unwrap in block ${settledAt} is final; epoch ends at ${toBlock}`);
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
    // 5. Rebuild from scratch on the second provider: its own amount, its own samples, its own scores.
    if (verifierUrl) {
        const second = makeClient(verifierUrl);
        await sameChainAt(publicClient, second, toBlock);
        const again = await buildEpoch(second, a, { fromBlock, toBlock, epochId: nextEpochId, config: epoch.config });
        fail(epochMismatches(epoch, again), "the second RPC built a different epoch; not posting");
        console.log(`verified against the second RPC: ${epoch.root}`);
    }

    // 6. Building took a while: read the pool again and post only if this epoch still fits it exactly.
    fail(prePostProblems(epoch, await poolState(publicClient, a.pool)), `epoch ${epoch.epochId} cannot be posted`);
    if (dryRun || !wallet) {
        console.log(`dry run: would post root ${epoch.root} for ${epoch.total} wei`);
        return;
    }

    // 7. Post with the POSTER role and read back what the pool recorded. Claims open POST_DELAY later; the guardian
    //    can cancel until then. A key without the role hands the call to the pool owner instead.
    const dataURI = `${publicUrl}/${epoch.epochId}`;
    const sender = typeof account === "string" ? account : account!.address;
    const [poolOwner, canPost] = await Promise.all([
        publicClient.readContract({ address: a.pool, abi: opsAbi, functionName: "owner" }),
        publicClient.readContract({ address: a.pool, abi: opsAbi, functionName: "hasAnyRole", args: [sender, POSTER_ROLE] }),
    ]);
    if (!canPost && poolOwner.toLowerCase() !== sender.toLowerCase()) {
        const path = writeProposal(epoch, a.pool, poolOwner, dataURI, await publicClient.getChainId());
        console.log(`epoch ${epoch.epochId} proposed: ${path}`);
        console.log(`import it into the Transaction Builder of ${poolOwner}; signers verify ${dataURI} on their own RPC before signing`);
        return;
    }
    const hash = await wallet.writeContract({
        address: a.pool,
        abi: opsAbi,
        functionName: "postEpoch",
        args: [epoch.root, BigInt(epoch.total), BigInt(epoch.fromBlock), BigInt(epoch.toBlock), epoch.configHash, dataURI],
    });
    const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 600_000 });
    if (r.status !== "success") throw new Error(`postEpoch reverted: ${hash}`);
    const posted = await publicClient.readContract({
        address: a.pool,
        abi: opsAbi,
        functionName: "getEpoch",
        args: [BigInt(epoch.epochId)],
        blockNumber: r.blockNumber,
    });
    fail(
        postedMismatches(epoch, { root: posted.root, amount: posted.amount, fromBlock: posted.fromBlock, toBlock: posted.toBlock }),
        `epoch ${epoch.epochId} was posted (${hash}) but the pool recorded something else; stop claims tooling and investigate`,
    );
    console.log(`epoch ${epoch.epochId} posted in block ${r.blockNumber} and read back: ${hash}`);
    console.log(
        `claims open at ${new Date(Number(posted.claimableAt) * 1000).toISOString()}; until then the Operations Safe ` +
            `can cancelEpoch(${epoch.epochId}) if anything is wrong. Everyone can check it with: pnpm revshare verify <file>`,
    );
}

async function main() {
    const [command, ...args] = process.argv.slice(2);

    if (command === "build") {
        const from = flag(args, "from");
        const to = flag(args, "to");
        const id = flag(args, "epoch");
        if (!from || !to) throw new Error("build needs --from and --to");
        // Read from the pool by default, the id could change before the post and orphan every leaf.
        if (!id) throw new Error("build needs --epoch <id>: the pool's next epoch id, as you intend to post it");
        const epoch = await buildEpoch(publicClient, addresses(), {
            fromBlock: BigInt(from),
            toBlock: BigInt(to),
            epochId: BigInt(id),
            amount: flag(args, "amount") ? BigInt(flag(args, "amount")!) : undefined,
        });
        const path = writeEpochFile(epoch);
        const publicUrl = (process.env.REVSHARE_PUBLIC_URL ?? "https://api.normies.art/revshare/epochs").replace(/\/$/, "");
        console.log(`epoch ${epoch.epochId}: ${epoch.leaves.length} payouts, ${epoch.total} wei of ${epoch.amount} -> ${path}`);
        console.log(`samples: ${epoch.sampleBlocks.join(", ")}`);
        console.log(`next, on a second, independent RPC (it must print "verified" and "postable"):`);
        console.log(`  RPC_URL=<second rpc> pnpm revshare verify ${path}`);
        console.log(`then, and only then:`);
        console.log(
            `  cast send ${epoch.addresses.pool} "postEpoch(bytes32,uint256,uint64,uint64,bytes32,string)" ${epoch.root} ${epoch.total} ${epoch.fromBlock} ${epoch.toBlock} ${epoch.configHash} "${publicUrl}/${epoch.epochId}"`,
        );
        return;
    }

    if (command === "verify") {
        const path = args[0];
        if (!path) throw new Error("verify needs a path to an epoch file");
        const file = JSON.parse(readFileSync(path, "utf8")) as EpochFile;
        const a = addresses();
        const options = { fromBlock: BigInt(file.fromBlock), toBlock: BigInt(file.toBlock), epochId: BigInt(file.epochId), config: file.config };
        // The amount is recomputed from the pool at toBlock, unless the file was built with a deliberate --amount.
        const [balance, outstanding] = await Promise.all([
            publicClient.getBalance({ address: a.pool, blockNumber: options.toBlock }),
            publicClient.readContract({ address: a.pool, abi: opsAbi, functionName: "outstanding", blockNumber: options.toBlock }),
        ]);
        const chainAmount = (balance - outstanding).toString();
        const rebuilt = await buildEpoch(publicClient, a, chainAmount === file.amount ? options : { ...options, amount: BigInt(file.amount) });
        if (chainAmount !== file.amount) {
            console.warn(`note: the file distributes ${file.amount} wei; the pool held ${chainAmount} wei unreserved at block ${file.toBlock}`);
        }
        const problems = epochMismatches(file, rebuilt);
        if (problems.length > 0) {
            console.error(`MISMATCH epoch ${file.epochId}:\n  - ${problems.join("\n  - ")}`);
            process.exit(1);
        }
        console.log(`epoch ${file.epochId} verified: ${file.root}`);

        const pool = await poolState(publicClient, a.pool);
        if (BigInt(file.epochId) < pool.nextEpochId) {
            const posted = await publicClient.readContract({ address: a.pool, abi: opsAbi, functionName: "getEpoch", args: [BigInt(file.epochId)] });
            if (posted.status === STATUS_CANCELLED) {
                console.error(`CANCELLED epoch ${file.epochId}: it was withdrawn before its claims opened; its range is posted again under a new id`);
                process.exit(1);
            }
            const differs = postedMismatches(file, { root: posted.root, amount: posted.amount, fromBlock: posted.fromBlock, toBlock: posted.toBlock });
            if (differs.length > 0) {
                console.error(`POSTED DIFFERENTLY epoch ${file.epochId}:\n  - ${differs.join("\n  - ")}`);
                process.exit(1);
            }
            console.log(`epoch ${file.epochId} matches what the pool recorded`);
            return;
        }
        const blockers = prePostProblems(file, pool);
        if (blockers.length > 0) {
            console.error(`NOT POSTABLE epoch ${file.epochId}:\n  - ${blockers.join("\n  - ")}`);
            process.exit(1);
        }
        console.log(`epoch ${file.epochId} is postable now`);
        return;
    }

    if (command === "run") {
        await runEpoch(args.includes("--dry-run"), args.includes("--replace-proposal"));
        return;
    }

    console.error("usage: revshare build --epoch <id> --from <block> --to <block> [--amount <wei>] | verify <epoch.json> | run [--dry-run] [--replace-proposal]");
    process.exit(1);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});

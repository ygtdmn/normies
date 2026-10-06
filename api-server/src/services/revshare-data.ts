import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { parseAbi } from "viem";
import {
    CANVAS_STORAGE_V2_ADDRESS,
    CANVAS_V2_ADDRESS,
    MARKET_ADDRESS,
    MARKET_CACHE_TTL_MS,
    REVENUE_POOL_ADDRESS,
    REVSHARE_DIR,
    ROYALTY_SPLITTER_ADDRESS,
} from "../config.js";
import type { EpochFile } from "../revshare/index.js";
import { REVSHARE_CONFIG } from "../revshare/index.js";
import { scoreWallet, type ScoreBreakdown, type WalletState } from "../revshare/index.js";
import { publicClient } from "./chain.js";
import { ponderFetch } from "./ponder-data.js";

// ──────────────────────────────────────────────
//  Revenue share reads. Live scores come from the indexer's state snapshot and
//  are a PROJECTION: what an epoch actually pays is computed from RPC state at
//  sampled blocks (src/revshare/build.ts) and published as an epoch file.
// ──────────────────────────────────────────────

const LIVE_TTL_MS = 60_000;
const poolAbi = parseAbi([
    "function outstanding() view returns (uint256)",
    "function claimWindow() view returns (uint64)",
    "function paused() view returns (bool)",
    "function nextEpochId() view returns (uint256)",
    "function weth() view returns (address)",
]);
const splitterAbi = parseAbi(["function poolBps() view returns (uint16)"]);
const erc20Abi = parseAbi(["function balanceOf(address) view returns (uint256)"]);

export interface IndexedEpoch {
    epochId: string;
    root: string;
    amount: string;
    claimed: string;
    claims: number;
    fromBlock: string;
    toBlock: string;
    claimableAt: string;
    sweepableAt: string;
    configHash: string;
    dataURI: string;
    status: "posted" | "cancelled" | "swept";
    sweptAmount: string | null;
    blockNumber: string;
    timestamp: string;
    txHash: string;
}

export interface IndexedClaim {
    id: string;
    epochId: string;
    index: string;
    account: string;
    amount: string;
    blockNumber: string;
    timestamp: string;
    txHash: string;
}

interface StateResponse {
    owners: [string, string][];
    tokens: [string, string][];
    balances: [string, string][];
    listings: [string, number][];
}

interface LiveScores {
    at: number;
    wallets: Map<string, { state: WalletState; breakdown: ScoreBreakdown }>;
    totalScore: bigint;
}

let live: LiveScores | null = null;
let liveInFlight: Promise<LiveScores> | null = null;
async function excludedAddresses(): Promise<Set<string>> {
    const own = [MARKET_ADDRESS, REVENUE_POOL_ADDRESS, CANVAS_V2_ADDRESS, CANVAS_STORAGE_V2_ADDRESS, ROYALTY_SPLITTER_ADDRESS];
    return new Set([...REVSHARE_CONFIG.excluded, ...own.filter(Boolean).map((a) => (a as string).toLowerCase())]);
}

async function computeLive(): Promise<LiveScores> {
    const [state, excluded] = await Promise.all([ponderFetch<StateResponse>("/revshare/state"), excludedAddresses()]);
    const states = new Map<string, WalletState>();
    const wallet = (address: string) => {
        const key = address.toLowerCase();
        let w = states.get(key);
        if (!w) {
            w = { address: key, tokens: 0, pixels: 0n };
            states.set(key, w);
        }
        return w;
    };
    const attached = new Map(state.tokens.map(([id, amount]) => [id, BigInt(amount)]));
    for (const [tokenId, owner] of state.owners) {
        const w = wallet(owner);
        w.tokens += 1;
        w.pixels += attached.get(tokenId) ?? 0n;
    }
    for (const [address, balance] of state.balances) wallet(address).pixels += BigInt(balance);
    for (const [seller, remaining] of state.listings) wallet(seller).pixels += BigInt(remaining);

    const wallets = new Map<string, { state: WalletState; breakdown: ScoreBreakdown }>();
    let totalScore = 0n;
    for (const [address, walletState] of states) {
        if (excluded.has(address)) continue;
        const breakdown = scoreWallet(walletState);
        if (breakdown.score === 0n) continue;
        wallets.set(address, { state: walletState, breakdown });
        totalScore += breakdown.score;
    }
    return { at: Date.now(), wallets, totalScore };
}

/** Every scoring wallet, cached for a minute; concurrent callers share one computation. */
export async function getLiveScores(): Promise<LiveScores> {
    if (live && Date.now() - live.at < LIVE_TTL_MS) return live;
    if (!liveInFlight) {
        liveInFlight = computeLive()
            .then((result) => {
                live = result;
                return result;
            })
            .finally(() => {
                liveInFlight = null;
            });
    }
    return liveInFlight;
}

/** A fetched epoch file, or null when it is not published, kept for `until` (ms). */
const epochFiles = new Map<string, { file: EpochFile | null; until: number }>();
const FOUND_TTL_MS = 10 * 60_000;
const MISSING_TTL_MS = 60_000;

/**
 * An epoch's payout table. A local file in REVSHARE_DIR wins (a dev machine); otherwise it is read from the job's
 * folder on the indexer host (/revshare-epochs/<id>.json, with the indexer secret). /revshare/files/<id>.json serves
 * it publicly, which is the epoch's on-chain dataURI. Callers still compare its root with the indexed epoch.
 */
export async function loadEpochFile(epochId: string): Promise<EpochFile | null> {
    if (!/^\d+$/.test(epochId)) return null;
    const path = join(REVSHARE_DIR, "epochs", `${epochId}.json`);
    if (existsSync(path)) {
        try {
            return JSON.parse(readFileSync(path, "utf8")) as EpochFile;
        } catch {
            return null;
        }
    }
    const cached = epochFiles.get(epochId);
    if (cached && cached.until > Date.now()) return cached.file;
    let file: EpochFile | null = null;
    try {
        const parsed = await ponderFetch<EpochFile>(`/revshare-epochs/${epochId}.json`);
        if (parsed.epochId === epochId && Array.isArray(parsed.leaves)) file = parsed;
    } catch {
        // Not there (404) or unreachable right now: treated as not published, retried after the short TTL.
    }
    epochFiles.set(epochId, { file, until: Date.now() + (file ? FOUND_TTL_MS : MISSING_TTL_MS) });
    return file;
}

export const getEpochs = () => ponderFetch<{ epochs: IndexedEpoch[] }>("/revshare/epochs");
export const getEpoch = (id: string) => ponderFetch<IndexedEpoch>(`/revshare/epochs/${id}`);
export const getClaims = (address: string) => ponderFetch<{ claims: IndexedClaim[] }>(`/revshare/claims/${address.toLowerCase()}`);
export const getRevshareStats = () => ponderFetch<Record<string, unknown>>("/revshare/stats");

let statusCache: { at: number; value: Record<string, unknown> } | null = null;

/** The royalty splitter's ETH and WETH, and the holders' part of it (poolBps): royalties not yet released. */
async function splitterPending(weth: `0x${string}`) {
    const splitter = ROYALTY_SPLITTER_ADDRESS;
    if (!splitter) return null;
    const [eth, wrapped, poolBps] = await Promise.all([
        publicClient.getBalance({ address: splitter }),
        publicClient.readContract({ address: weth, abi: erc20Abi, functionName: "balanceOf", args: [splitter] }),
        publicClient.readContract({ address: splitter, abi: splitterAbi, functionName: "poolBps" }),
    ]);
    return { eth, wrapped, poolBps: Number(poolBps), toPool: ((eth + wrapped) * BigInt(poolBps)) / 10_000n };
}

/**
 * Pool balances straight from the chain (a claim depends on them), totals from the indexer, and where the money
 * comes from: market fees arrive in the pool on every fill; royalties wait in the splitter until release(), which
 * the epoch job calls before it builds. `availableWei` is what the next epoch would split if it were built now.
 */
export async function getPoolStatus(): Promise<Record<string, unknown>> {
    if (statusCache && Date.now() - statusCache.at < MARKET_CACHE_TTL_MS) return statusCache.value;
    const address = REVENUE_POOL_ADDRESS!;
    const [balance, outstanding, claimWindow, paused, nextEpochId, weth, stats, market] = await Promise.all([
        publicClient.getBalance({ address }),
        publicClient.readContract({ address, abi: poolAbi, functionName: "outstanding" }),
        publicClient.readContract({ address, abi: poolAbi, functionName: "claimWindow" }),
        publicClient.readContract({ address, abi: poolAbi, functionName: "paused" }),
        publicClient.readContract({ address, abi: poolAbi, functionName: "nextEpochId" }),
        publicClient.readContract({ address, abi: poolAbi, functionName: "weth" }),
        getRevshareStats().catch(() => null),
        ponderFetch<{ feesToPoolWei?: string }>("/market/stats").catch(() => null),
    ]);
    const pending = await splitterPending(weth).catch(() => null);
    const unallocated = balance - outstanding;
    const royaltiesReleased = BigInt((stats as { royaltiesToPoolWei?: string } | null)?.royaltiesToPoolWei ?? "0");
    const value = {
        poolAddress: address,
        splitterAddress: ROYALTY_SPLITTER_ADDRESS ?? null,
        balanceWei: balance.toString(),
        outstandingWei: outstanding.toString(),
        unallocatedWei: unallocated.toString(),
        availableWei: (unallocated + (pending?.toPool ?? 0n)).toString(),
        sources: {
            // All time, paid straight into the pool on every market fill.
            marketFeesWei: market?.feesToPoolWei ?? null,
            // All time: released into the pool, plus the holders' part still waiting in the splitter.
            royaltiesReleasedWei: royaltiesReleased.toString(),
            royaltiesPendingWei: pending ? pending.toPool.toString() : null,
        },
        splitter: pending
            ? { ethWei: pending.eth.toString(), wethWei: pending.wrapped.toString(), poolBps: pending.poolBps }
            : null,
        // Default for future posts only; use each epoch's sweepableAt for existing payouts.
        claimWindowSeconds: Number(claimWindow),
        paused,
        nextEpochId: nextEpochId.toString(),
        totals: stats,
    };
    statusCache = { at: Date.now(), value };
    return value;
}

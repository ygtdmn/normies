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
]);

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

export function loadEpochFile(epochId: string): EpochFile | null {
    if (!/^\d+$/.test(epochId)) return null;
    const path = join(REVSHARE_DIR, "epochs", `${epochId}.json`);
    if (!existsSync(path)) return null;
    try {
        return JSON.parse(readFileSync(path, "utf8")) as EpochFile;
    } catch {
        return null;
    }
}

export const getEpochs = () => ponderFetch<{ epochs: IndexedEpoch[] }>("/revshare/epochs");
export const getEpoch = (id: string) => ponderFetch<IndexedEpoch>(`/revshare/epochs/${id}`);
export const getClaims = (address: string) => ponderFetch<{ claims: IndexedClaim[] }>(`/revshare/claims/${address.toLowerCase()}`);
export const getRevshareStats = () => ponderFetch<Record<string, unknown>>("/revshare/stats");

let statusCache: { at: number; value: Record<string, unknown> } | null = null;

/** Pool balances straight from the chain (a claim depends on them), totals from the indexer. */
export async function getPoolStatus(): Promise<Record<string, unknown>> {
    if (statusCache && Date.now() - statusCache.at < MARKET_CACHE_TTL_MS) return statusCache.value;
    const address = REVENUE_POOL_ADDRESS!;
    const [balance, outstanding, claimWindow, paused, nextEpochId, stats] = await Promise.all([
        publicClient.getBalance({ address }),
        publicClient.readContract({ address, abi: poolAbi, functionName: "outstanding" }),
        publicClient.readContract({ address, abi: poolAbi, functionName: "claimWindow" }),
        publicClient.readContract({ address, abi: poolAbi, functionName: "paused" }),
        publicClient.readContract({ address, abi: poolAbi, functionName: "nextEpochId" }),
        getRevshareStats().catch(() => null),
    ]);
    const value = {
        poolAddress: address,
        splitterAddress: ROYALTY_SPLITTER_ADDRESS ?? null,
        balanceWei: balance.toString(),
        outstandingWei: outstanding.toString(),
        unallocatedWei: (balance - outstanding).toString(),
        // Default for future posts only; use each epoch's sweepableAt for existing payouts.
        claimWindowSeconds: Number(claimWindow),
        paused,
        nextEpochId: nextEpochId.toString(),
        totals: stats,
    };
    statusCache = { at: Date.now(), value };
    return value;
}

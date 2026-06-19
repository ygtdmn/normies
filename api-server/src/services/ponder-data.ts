import { PONDER_API_SECRET, PONDER_API_URL } from "../config.js";
import {
    agentBindingCache,
    agentBindingNullTtlMs,
    transformHistoryCache,
} from "./cache.js";

function ponderHeaders(init: Record<string, string>): Record<string, string> {
    return PONDER_API_SECRET
        ? { ...init, "X-Ponder-Secret": PONDER_API_SECRET }
        : { ...init };
}

async function ponderFetch<T>(path: string): Promise<T> {
    let res: Response;
    try {
        res = await fetch(`${PONDER_API_URL}${path}`, {
            headers: ponderHeaders({ "Accept": "application/json" }),
            signal: AbortSignal.timeout(15_000),
        });
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new Error(`Ponder API request failed: ${message}`);
    }
    if (!res.ok) {
        const body = await res.text().catch(() => "");
        throw new Error(`Ponder API ${res.status}: ${body}`);
    }
    return res.json() as Promise<T>;
}

async function ponderPost<T>(path: string, body: unknown): Promise<T> {
    let res: Response;
    try {
        res = await fetch(`${PONDER_API_URL}${path}`, {
            method: "POST",
            headers: ponderHeaders({ "Content-Type": "application/json", Accept: "application/json" }),
            body: JSON.stringify(body),
            signal: AbortSignal.timeout(15_000),
        });
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new Error(`Ponder API request failed: ${message}`);
    }
    if (!res.ok) {
        const text = await res.text().catch(() => "");
        throw new Error(`Ponder API ${res.status}: ${text}`);
    }
    return res.json() as Promise<T>;
}

// ──────────────────────────────────────────────
//  Types
// ──────────────────────────────────────────────

export interface BurnCommitmentData {
    commitId: string;
    owner: string;
    receiverTokenId: string;
    tokenCount: number;
    transferredActionPoints: string;
    blockNumber: string;
    timestamp: string;
    txHash: string;
    revealed: boolean;
    totalActions: string | null;
    expired: boolean | null;
    revealBlockNumber: string | null;
    revealTimestamp: string | null;
    revealTxHash: string | null;
}

export interface BurnCommitmentDetail extends BurnCommitmentData {
    burnedTokens: BurnedTokenData[];
}

export interface BurnedTokenData {
    id: string;
    commitId: string;
    tokenId: string;
    pixelCount: number;
    blockNumber: string;
    timestamp: string;
}

export interface TransformData {
    id: string;
    tokenId: string;
    transformer: string;
    changeCount: number;
    newPixelCount: number;
    transformBitmap?: string;
    blockNumber: string;
    timestamp: string;
    txHash: string;
    version?: number;
}

export interface StatsData {
    totalBurnCommitments: number;
    totalBurnedTokens: number;
    totalTransforms: number;
    totalTokenData: number;
    totalZombies: number;
    totalLegendaryCanvases: number;
    totalActionPointsDistributed: string;
}

export interface IndexedTokenData {
    tokenId: string;
    rawImageData: `0x${string}`;
    traitsHex: `0x${string}`;
    blockNumber: string;
    timestamp: string;
    txHash: `0x${string}`;
}

export interface IndexedCanvasState {
    tokenId: string;
    actionPoints: string;
    customized: boolean;
    delegate: `0x${string}`;
    delegateSetBy: `0x${string}`;
    latestTransformBitmap: `0x${string}` | null;
    blockNumber: string;
    timestamp: string;
    txHash: `0x${string}`;
}

export interface IndexedZombieState {
    tokenId: string;
    isZombie: boolean;
    poolIndex: string | null;
    bitmap: `0x${string}` | null;
    attributesJson: string | null;
    qualifyingWallet: string | null;
    commitId: string | null;
    blockNumber: string | null;
    timestamp: string | null;
    txHash: `0x${string}` | null;
}

export interface IndexedZombieConversion {
    commitId: string;
    qualifyingWallet: string;
    tokenId: string;
    index: string;
    committer: string;
    committedOwner: string;
    blockNumber: string;
    timestamp: string;
    txHash: `0x${string}`;
    revealed: boolean;
    cancelled: boolean;
    poolIndex: string | null;
    revealBlockNumber: string | null;
    revealTimestamp: string | null;
    revealTxHash: `0x${string}` | null;
    cancelBlockNumber: string | null;
    cancelTimestamp: string | null;
    cancelTxHash: `0x${string}` | null;
}

export interface IndexedZombieStatus {
    paused: boolean;
    merkleRoot: `0x${string}` | null;
    seedBlock: string | null;
    seed: `0x${string}` | null;
    seedLocked: boolean;
    poolSize: number;
    poolSealed: boolean;
    blockNumber: string | null;
    timestamp: string | null;
    txHash: `0x${string}` | null;
}

export interface IndexedLegendaryCanvasState {
    tokenId: string;
    isLegendary: boolean;
    artistName: string | null;
    operator: `0x${string}` | null;
    blockNumber: string | null;
    timestamp: string | null;
    txHash: `0x${string}` | null;
}

// ──────────────────────────────────────────────
//  Ownership
// ──────────────────────────────────────────────

export interface TokenOwnerData {
    tokenId: string;
    owner: string;
}

export async function getTokenOwner(tokenId: number): Promise<TokenOwnerData> {
    return ponderFetch(`/owner/${tokenId}`);
}

export async function getTokensByHolder(address: string): Promise<string[]> {
    return ponderFetch(`/tokens/${address.toLowerCase()}`);
}

// ──────────────────────────────────────────────
//  Token data & Canvas state
// ──────────────────────────────────────────────

export async function getIndexedTokenData(tokenId: number): Promise<IndexedTokenData> {
    return ponderFetch(`/token-data/${tokenId}`);
}

export async function getIndexedTokenDataBatch(
    tokenIds: (number | bigint | string)[],
): Promise<Record<string, IndexedTokenData>> {
    const res = await ponderPost<{ tokens: Record<string, IndexedTokenData> }>("/token-data/batch", {
        tokenIds: tokenIds.map((tokenId) => tokenId.toString()),
    });
    return res.tokens ?? {};
}

export async function getIndexedTokenDataCount(): Promise<number> {
    const res = await ponderFetch<{ count: number }>("/token-data/count");
    return res.count;
}

export async function getIndexedCanvasState(tokenId: number): Promise<IndexedCanvasState> {
    return ponderFetch(`/canvas-state/${tokenId}`);
}

export async function getIndexedCanvasStateBatch(
    tokenIds: (number | bigint | string)[],
): Promise<Record<string, IndexedCanvasState>> {
    const res = await ponderPost<{ states: Record<string, IndexedCanvasState> }>("/canvas-state/batch", {
        tokenIds: tokenIds.map((tokenId) => tokenId.toString()),
    });
    return res.states ?? {};
}

// ──────────────────────────────────────────────
//  Zombie state
// ──────────────────────────────────────────────

export async function getIndexedZombieState(tokenId: number): Promise<IndexedZombieState> {
    return ponderFetch(`/zombie-state/${tokenId}`);
}

export async function getIndexedZombieStateBatch(
    tokenIds: (number | bigint | string)[],
): Promise<Record<string, IndexedZombieState>> {
    const res = await ponderPost<{ states: Record<string, IndexedZombieState> }>("/zombie-state/batch", {
        tokenIds: tokenIds.map((tokenId) => tokenId.toString()),
    });
    return res.states ?? {};
}

export async function getIndexedZombieConversions(
    limit = 50,
    offset = 0,
): Promise<IndexedZombieConversion[]> {
    return ponderFetch(`/zombies/conversions?limit=${limit}&offset=${offset}`);
}

export async function getIndexedZombieConversionsForWallet(
    address: string,
    limit = 50,
    offset = 0,
): Promise<IndexedZombieConversion[]> {
    return ponderFetch(`/zombies/wallet/${address.toLowerCase()}?limit=${limit}&offset=${offset}`);
}

export async function getIndexedZombieConversionsForToken(tokenId: number): Promise<IndexedZombieConversion[]> {
    return ponderFetch(`/zombies/token/${tokenId}`);
}

export async function getIndexedZombieStatus(): Promise<IndexedZombieStatus> {
    return ponderFetch("/zombies/status");
}

// ──────────────────────────────────────────────
//  Legendary Canvas
// ──────────────────────────────────────────────

export async function getIndexedLegendaryCanvasState(tokenId: number): Promise<IndexedLegendaryCanvasState> {
    return ponderFetch(`/legendary-canvas/${tokenId}`);
}

export async function getIndexedLegendaryCanvasStateBatch(
    tokenIds: (number | bigint | string)[],
): Promise<Record<string, IndexedLegendaryCanvasState>> {
    const res = await ponderPost<{ states: Record<string, IndexedLegendaryCanvasState> }>("/legendary-canvas/batch", {
        tokenIds: tokenIds.map((tokenId) => tokenId.toString()),
    });
    return res.states ?? {};
}

export async function getIndexedLegendaryCanvases(limit = 50, offset = 0): Promise<IndexedLegendaryCanvasState[]> {
    return ponderFetch(`/legendary-canvas?limit=${limit}&offset=${offset}`);
}

// ──────────────────────────────────────────────
//  Burns
// ──────────────────────────────────────────────

export async function getBurns(limit = 50, offset = 0): Promise<BurnCommitmentData[]> {
    return ponderFetch(`/burns?limit=${limit}&offset=${offset}`);
}

export async function getBurnCommitment(commitId: string): Promise<BurnCommitmentDetail> {
    return ponderFetch(`/burns/${commitId}`);
}

export async function getBurnsForAddress(address: string, limit = 50, offset = 0): Promise<BurnCommitmentData[]> {
    return ponderFetch(`/burns/address/${address}?limit=${limit}&offset=${offset}`);
}

export async function getBurnsForReceiver(tokenId: number, limit = 50, offset = 0): Promise<BurnCommitmentData[]> {
    return ponderFetch(`/burns/receiver/${tokenId}?limit=${limit}&offset=${offset}`);
}

export async function getBurnedTokens(limit = 50, offset = 0): Promise<BurnedTokenData[]> {
    return ponderFetch(`/burned-tokens?limit=${limit}&offset=${offset}`);
}

export async function getBurnedToken(tokenId: number): Promise<BurnedTokenData[]> {
    return ponderFetch(`/burned-tokens/${tokenId}`);
}

// ──────────────────────────────────────────────
//  Transforms
// ──────────────────────────────────────────────

export async function getTransformHistory(tokenId: number, limit = 50, offset = 0): Promise<TransformData[]> {
    // Only the default page (offset=0, full limit) goes through cache — paginated
    // callers are rare and benefit less from a hit-rate boost than they suffer
    // from cache pollution.
    if (offset === 0 && limit === 50) {
        const cached = transformHistoryCache.get(tokenId) as TransformData[] | undefined;
        if (cached) return cached;
        const fresh = await ponderFetch<TransformData[]>(`/transforms/${tokenId}?limit=${limit}&offset=${offset}`);
        transformHistoryCache.set(tokenId, fresh);
        return fresh;
    }
    return ponderFetch(`/transforms/${tokenId}?limit=${limit}&offset=${offset}`);
}

export async function getTransformLatest(tokenId: number): Promise<TransformData> {
    return ponderFetch(`/transforms/${tokenId}/latest`);
}

export async function getTransformVersion(tokenId: number, version: number): Promise<TransformData> {
    return ponderFetch(`/transforms/${tokenId}/${version}`);
}

// ──────────────────────────────────────────────
//  Stats
// ──────────────────────────────────────────────

export async function getStats(): Promise<StatsData> {
    return ponderFetch("/stats");
}

// ──────────────────────────────────────────────
//  Adapter8004 — Agent Bindings
// ──────────────────────────────────────────────

export interface AgentBindingData {
    id: string;
    agentId: string;
    standard: number;
    tokenContract: string;
    tokenId: string;
    registeredBy: string;
    blockNumber: string;
    timestamp: string;
    txHash: string;
}

export async function getAgentBinding(
    tokenContract: string,
    tokenId: number | bigint | string,
): Promise<AgentBindingData | null> {
    const key = `t:${tokenContract.toLowerCase()}:${tokenId.toString()}`;
    const cached = agentBindingCache.get(key);
    if (cached) return cached.v as AgentBindingData | null;
    const res = await ponderFetch<{ binding: AgentBindingData | null }>(
        `/agent-binding/${tokenContract.toLowerCase()}/${tokenId.toString()}`,
    );
    // Bindings are immutable once seen — long TTL for hits. Misses get the
    // short TTL so newly registered agents stop 404ing quickly.
    agentBindingCache.set(key, { v: res.binding }, res.binding ? undefined : { ttl: agentBindingNullTtlMs });
    return res.binding;
}

export async function getAgentBindings(
    tokenContract: string,
    tokenIds: (number | bigint | string)[],
): Promise<Record<string, AgentBindingData>> {
    const res = await ponderPost<{ bindings: Record<string, AgentBindingData> }>("/agent-binding/batch", {
        tokenContract: tokenContract.toLowerCase(),
        tokenIds: tokenIds.map((t) => t.toString()),
    });
    return res.bindings ?? {};
}

export async function getAgentBindingByAgentId(
    agentId: number | bigint | string,
): Promise<AgentBindingData | null> {
    const key = `a:${agentId.toString()}`;
    const cached = agentBindingCache.get(key);
    if (cached) return cached.v as AgentBindingData | null;
    const res = await ponderFetch<{ binding: AgentBindingData | null }>(
        `/agent/${agentId.toString()}`,
    );
    agentBindingCache.set(key, { v: res.binding }, res.binding ? undefined : { ttl: agentBindingNullTtlMs });
    return res.binding;
}

/**
 * Paginated list of bindings. Default sort is `desc` (newest agentId first).
 * Pass `cursor` for keyset pagination (returns rows past the cursor in the
 * sort direction); omit it for offset paging, which the reconciler uses for
 * full sweeps. Optional `tokenContract` filter restricts to a single NFT
 * contract.
 */
export async function getAllAgentBindings(opts: {
    tokenContract?: string;
    limit?: number;
    offset?: number;
    cursor?: bigint | string;
    sort?: "asc" | "desc";
} = {}): Promise<{ bindings: AgentBindingData[]; hasMore: boolean }> {
    const params = new URLSearchParams();
    if (opts.tokenContract) params.set("tokenContract", opts.tokenContract.toLowerCase());
    if (opts.limit !== undefined) params.set("limit", String(opts.limit));
    if (opts.offset !== undefined) params.set("offset", String(opts.offset));
    if (opts.cursor !== undefined) params.set("cursor", opts.cursor.toString());
    if (opts.sort) params.set("sort", opts.sort);
    const qs = params.toString();
    return ponderFetch<{ bindings: AgentBindingData[]; hasMore: boolean }>(
        qs ? `/agent-bindings?${qs}` : "/agent-bindings",
    );
}

export async function countAgentBindings(opts: {
    tokenContract?: string;
} = {}): Promise<number> {
    const params = new URLSearchParams();
    if (opts.tokenContract) params.set("tokenContract", opts.tokenContract.toLowerCase());
    const qs = params.toString();
    const res = await ponderFetch<{ count: number }>(
        qs ? `/agent-bindings/count?${qs}` : "/agent-bindings/count",
    );
    return res.count;
}

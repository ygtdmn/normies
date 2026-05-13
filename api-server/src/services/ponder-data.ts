import { PONDER_API_URL } from "../config.js";

async function ponderFetch<T>(path: string): Promise<T> {
    const res = await fetch(`${PONDER_API_URL}${path}`, {
        headers: { "Accept": "application/json" },
        signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) {
        const body = await res.text().catch(() => "");
        throw new Error(`Ponder API ${res.status}: ${body}`);
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
    totalActionPointsDistributed: string;
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
    const res = await ponderFetch<{ binding: AgentBindingData | null }>(
        `/agent-binding/${tokenContract.toLowerCase()}/${tokenId.toString()}`,
    );
    return res.binding;
}

export async function getAgentBindings(
    tokenContract: string,
    tokenIds: (number | bigint | string)[],
): Promise<Record<string, AgentBindingData>> {
    const body = JSON.stringify({
        tokenContract: tokenContract.toLowerCase(),
        tokenIds: tokenIds.map((t) => t.toString()),
    });
    const res = await fetch(`${PONDER_API_URL}/agent-binding/batch`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body,
        signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) {
        const txt = await res.text().catch(() => "");
        throw new Error(`Ponder API ${res.status}: ${txt}`);
    }
    const json = (await res.json()) as { bindings: Record<string, AgentBindingData> };
    return json.bindings ?? {};
}

export async function getAgentBindingByAgentId(
    agentId: number | bigint | string,
): Promise<AgentBindingData | null> {
    const res = await ponderFetch<{ binding: AgentBindingData | null }>(
        `/agent/${agentId.toString()}`,
    );
    return res.binding;
}

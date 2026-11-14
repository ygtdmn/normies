import { ponderFetch } from "./ponder-data.js";

// ──────────────────────────────────────────────
//  Normies Arena read model: thin typed proxies over the indexer's /arena/* routes.
//  Everything is derived from NormiesArenaStorage events. Amounts are #PIXEL as strings.
// ──────────────────────────────────────────────

export type ArenaRoundStatus = "upcoming" | "open" | "finished" | "settled" | "cancelled";

export interface ArenaRoundData {
    round: number;
    status: ArenaRoundStatus;
    admissionsOpen: boolean;
    /** sponsorship + fees. */
    pool: string;
    sponsorship: string;
    fees: string;
    /** Pixels of the pool not yet credited, moved or released. */
    unpaid: string;
    resultHash: string | null;
    started: boolean;
    closed: boolean;
    finished: boolean;
    settled: boolean;
    cancelled: boolean;
    ticketCutoff: string | null;
    /** Rules, null until the round starts. */
    capacity: number | null;
    price: string | null;
    winnerBps: number | null;
    free: boolean | null;
    players: number;
    /** Winners paid at settlement. */
    winners: number;
    /** Winners the round pays under its rules: ceil(players * winnerBps / 10,000). */
    winnerCount: number | null;
    paid: string;
    refunded: string;
    movedOut: string;
    carriedTo: number | null;
    startedAt: string | null;
    startedBlock: string | null;
    startedTxHash: string | null;
    finishedAt: string | null;
    finishedTxHash: string | null;
    endedAt: string | null;
    endedTxHash: string | null;
    blockNumber: string;
    timestamp: string;
}

export interface ArenaStatusData {
    /** False while the indexer has no Arena storage address: every list is then empty. */
    indexed: boolean;
    storage: string | null;
    currentRound: number;
    round: ArenaRoundData | null;
    upcoming: ArenaRoundData[];
    unsettledRounds: number[];
    line: { waiting: number; newestTicket: string };
    totals: {
        balances: string;
        pools: string;
        roundsStarted: number;
        roundsSettled: number;
        roundsCancelled: number;
        admissions: number;
        pixelsPaid: string;
        pixelsSponsored: string;
        pixelsDeposited: string;
        pixelsWithdrawn: string;
        skinPurchases: number;
        skinPixels: string;
    };
    blockNumber: string | null;
    timestamp: string | null;
}

export interface ArenaRoundPlayerData {
    tokenId: string;
    /** Admission order, from 1. */
    seat: number;
    charged: string;
    /** Winner rank from 1, null for everyone else. */
    rank: number | null;
    prize: string | null;
    refund: string | null;
    owner: string | null;
    blockNumber: string;
    timestamp: string;
    txHash: string;
}

export interface ArenaQueueEntry {
    position: number;
    tokenId: string;
    ticket: string;
    balance: string;
    agentId: string | null;
    owner: string | null;
    burned: boolean;
    /** Whether the ticket can be admitted to the round taking admissions; null when none is. */
    eligible: boolean | null;
}

export interface ArenaNormieData {
    tokenId: string;
    balance: string;
    ticket: string | null;
    active: boolean;
    inLine: boolean;
    needsFunds: boolean;
    agentId: string | null;
    skins: number;
    roundsPlayed: number;
    wins: number;
    pixelsWon: string;
    pixelsRefunded: string;
    pixelsCharged: string;
    deposited: string;
    withdrawn: string;
    lastRound: number | null;
    blockNumber: string | null;
    timestamp: string | null;
    owner: string | null;
    burned: boolean;
    /** Place in the line from 1, null when not in it. Only on the single-Normie route. */
    position?: number | null;
}

export interface ArenaNormieRoundData {
    round: number;
    status: ArenaRoundStatus;
    seat: number;
    charged: string;
    rank: number | null;
    prize: string | null;
    refund: string | null;
    players: number;
    winners: number;
    pool: string;
    timestamp: string;
    txHash: string;
}

export interface ArenaEventData {
    id: string;
    kind: string;
    round: number | null;
    tokenId: string | null;
    account: string | null;
    amount: string | null;
    ref: string | null;
    needsFunds: boolean | null;
    blockNumber: string;
    timestamp: string;
    txHash: string;
    logIndex: number;
}

export interface ArenaSkinPurchaseData {
    purchaseId: string;
    tokenId: string;
    buyer: string;
    price: string;
    blockNumber: string;
    timestamp: string;
    txHash: string;
    logIndex: number;
}

export interface ArenaLeaderboardRow {
    position: number;
    tokenId: string;
    pixelsWon: string;
    wins: number;
    roundsPlayed: number;
    lastRound: number | null;
    agentId: string | null;
    owner: string | null;
}

export type ArenaLeaderboardSort = "pixels" | "wins" | "rounds";

function page(limit: number, offset: number): URLSearchParams {
    return new URLSearchParams({ limit: String(limit), offset: String(offset) });
}

/** The indexer answers 404 for a round it has no record of: hand that back as null instead of a 502. */
async function orNull<T>(request: Promise<T>): Promise<T | null> {
    try {
        return await request;
    } catch (err) {
        if (err instanceof Error && err.message.startsWith("Ponder API 404")) return null;
        throw err;
    }
}

export async function getArenaStatus(): Promise<ArenaStatusData> {
    return ponderFetch("/arena/status");
}

export async function getArenaRounds(opts: {
    status?: ArenaRoundStatus | "all";
    sort?: "asc" | "desc";
    limit?: number;
    offset?: number;
} = {}): Promise<{ rounds: ArenaRoundData[]; hasMore: boolean }> {
    const params = page(opts.limit ?? 50, opts.offset ?? 0);
    if (opts.status) params.set("status", opts.status);
    if (opts.sort) params.set("sort", opts.sort);
    return ponderFetch(`/arena/rounds?${params.toString()}`);
}

export async function getArenaRound(round: number): Promise<ArenaRoundData | null> {
    return orNull(ponderFetch<ArenaRoundData>(`/arena/rounds/${round}`));
}

export async function getArenaRoundPlayers(round: number, limit = 300, offset = 0): Promise<{
    round: number;
    status: ArenaRoundStatus;
    total: number;
    players: ArenaRoundPlayerData[];
    hasMore: boolean;
} | null> {
    return orNull(ponderFetch(`/arena/rounds/${round}/players?${page(limit, offset).toString()}`));
}

export async function getArenaRoundWinners(round: number, limit = 300, offset = 0): Promise<{
    round: number;
    status: ArenaRoundStatus;
    resultHash: string | null;
    pool: string;
    total: number;
    winners: ArenaRoundPlayerData[];
    hasMore: boolean;
} | null> {
    return orNull(ponderFetch(`/arena/rounds/${round}/winners?${page(limit, offset).toString()}`));
}

export async function getArenaQueue(limit = 50, offset = 0): Promise<{
    total: number;
    newestTicket: string;
    admittingRound: number | null;
    ticketCutoff: string | null;
    queue: ArenaQueueEntry[];
    hasMore: boolean;
}> {
    return ponderFetch(`/arena/queue?${page(limit, offset).toString()}`);
}

export async function getArenaNormie(tokenId: number): Promise<ArenaNormieData> {
    return ponderFetch(`/arena/normie/${tokenId}`);
}

export async function getArenaNormieRounds(tokenId: number, limit = 50, offset = 0): Promise<{
    tokenId: string;
    rounds: ArenaNormieRoundData[];
    hasMore: boolean;
}> {
    return ponderFetch(`/arena/normie/${tokenId}/rounds?${page(limit, offset).toString()}`);
}

export async function getArenaHolder(address: string): Promise<{
    address: string;
    balance: string;
    pixelsWon: string;
    inLine: number;
    needsFunds: number;
    normies: ArenaNormieData[];
}> {
    return ponderFetch(`/arena/holder/${address.toLowerCase()}`);
}

export async function getArenaActivity(opts: {
    kind?: string;
    round?: number;
    tokenId?: number;
    address?: string;
    limit?: number;
    offset?: number;
} = {}): Promise<{ events: ArenaEventData[]; hasMore: boolean }> {
    const params = page(opts.limit ?? 50, opts.offset ?? 0);
    if (opts.kind) params.set("kind", opts.kind);
    if (opts.round !== undefined) params.set("round", String(opts.round));
    if (opts.tokenId !== undefined) params.set("tokenId", String(opts.tokenId));
    if (opts.address) params.set("address", opts.address.toLowerCase());
    return ponderFetch(`/arena/activity?${params.toString()}`);
}

export async function getArenaSkins(opts: { buyer?: string; limit?: number; offset?: number } = {}): Promise<{
    total: number;
    pixels: string;
    purchases: ArenaSkinPurchaseData[];
    hasMore: boolean;
}> {
    const params = page(opts.limit ?? 50, opts.offset ?? 0);
    if (opts.buyer) params.set("buyer", opts.buyer.toLowerCase());
    return ponderFetch(`/arena/skins?${params.toString()}`);
}

export async function getArenaNormieSkins(tokenId: number): Promise<{
    tokenId: string;
    count: number;
    purchases: ArenaSkinPurchaseData[];
}> {
    return ponderFetch(`/arena/skins/normie/${tokenId}`);
}

export async function getArenaLeaderboard(sort: ArenaLeaderboardSort = "pixels", limit = 50, offset = 0): Promise<{
    sort: ArenaLeaderboardSort;
    leaderboard: ArenaLeaderboardRow[];
    hasMore: boolean;
}> {
    const params = page(limit, offset);
    params.set("sort", sort);
    return ponderFetch(`/arena/leaderboard?${params.toString()}`);
}

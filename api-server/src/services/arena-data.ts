import { ponderFetch } from "./ponder-data.js";

// ──────────────────────────────────────────────
//  Normies Arena read model: thin typed proxies over the indexer's /arena/* routes.
//  Everything is derived from NormiesArenaStorage (v3) events. Amounts are #PIXEL as strings. Rows with source
//  "v2" are history from the retired v2 storage.
// ──────────────────────────────────────────────

export type ArenaRoundStatus = "upcoming" | "open" | "ended" | "cancelled";
/** NormiesArenaStorage STATE_*: 0 unregistered, 1 active, 2 short, 3 cleared. */
export type ArenaNormieState = "unregistered" | "active" | "short" | "cleared";
export type ArenaRegisteredState = "all" | "active" | "short";
export type ArenaSource = "v2" | "v3";

export interface ArenaRoundData {
    round: number;
    status: ArenaRoundStatus;
    /** sponsorship + fees (the storage's poolOf). */
    pool: string;
    /** Sponsorship, including pools rolled in from the round before and pools moved from v2. */
    sponsorship: string;
    /** players x price, charged when a paid round starts. */
    fees: string;
    /** Pixels of the pool not yet credited, rolled or released. */
    unpaid: string;
    /** Credited from the pool: prizes plus refunds. */
    paid: string;
    prizes: string;
    refunds: string;
    winners: number;
    refundees: number;
    /** Unpaid pool rolled to the next round when this one ended or was cancelled, and pool rolled in. */
    rolled: string;
    rolledIn: string;
    /** Sponsorship moved from the v2 storage at the cutover. */
    migrated: string;
    started: boolean;
    ended: boolean;
    cancelled: boolean;
    /** Null until the round starts. */
    price: string | null;
    free: boolean | null;
    /** C after the round started. */
    cumulative: string | null;
    players: number;
    startedAt: string | null;
    startedBlock: string | null;
    startedTxHash: string | null;
    /** Ended or cancelled. */
    endedAt: string | null;
    endedTxHash: string | null;
    blockNumber: string;
    timestamp: string;
}

export interface ArenaStatusData {
    /** False while the indexer has no v3 storage address: every list is then empty. */
    indexed: boolean;
    storage: string | null;
    /** The retired v2 storage, indexed for history only. */
    legacyStorage: string | null;
    currentRound: number;
    currentFree: boolean;
    /** C: the sum of every started round's price. */
    cumulative: string;
    /** The current round while it is open, else null. */
    openRound: number | null;
    round: ArenaRoundData | null;
    upcoming: ArenaRoundData[];
    normies: { registered: number; active: number; short: number; cleared: number };
    totals: {
        balances: string;
        pools: string;
        roundsStarted: number;
        roundsEnded: number;
        roundsCancelled: number;
        playerEntries: number;
        pixelsCharged: string;
        prizes: string;
        refunds: string;
        pixelsSponsored: string;
        pixelsDeposited: string;
        pixelsWithdrawn: string;
        pixelsRescued: string;
        balancesMigrated: string;
        poolsMigrated: string;
        skinPurchases: number;
        skinPixels: string;
    };
    blockNumber: string | null;
    timestamp: string | null;
}

export interface ArenaRoundPlayerData {
    tokenId: string;
    /** Played the round (fixed when it started); false for a Normie only credited from its pool. */
    played: boolean;
    charged: string;
    /** Order of its first prize credit in the round's payout calls, from 1; null for everyone else. */
    payoutOrder: number | null;
    prize: string | null;
    refund: string | null;
    owner: string | null;
    blockNumber: string;
    timestamp: string;
    txHash: string;
}

export interface ArenaRegisteredEntry {
    tokenId: string;
    state: ArenaNormieState;
    balance: string;
    agentId: string | null;
    registeredRound: number | null;
    roundsPlayed: number;
    lastRound: number | null;
    owner: string | null;
    burned: boolean;
}

export interface ArenaNormieData {
    tokenId: string;
    state: ArenaNormieState;
    stateCode: number;
    /** Active or short. */
    registered: boolean;
    /** The storage's level: balance + C while active, the balance itself otherwise. */
    level: string;
    balance: string;
    /** The round open when it registered (0 before round 1); it plays from the next one. */
    registeredRound: number | null;
    agentId: string | null;
    skins: number;
    roundsPlayed: number;
    lastRound: number | null;
    wins: number;
    pixelsWon: string;
    pixelsRefunded: string;
    pixelsCharged: string;
    deposited: string;
    withdrawn: string;
    /** Balance moved from v2 at the cutover. */
    migrated: string;
    blockNumber: string | null;
    timestamp: string | null;
    owner: string | null;
    burned: boolean;
    /** Plays (or played) the current round. Only on the single-Normie route. */
    inCurrentRound?: boolean;
}

export interface ArenaNormieRoundData {
    round: number;
    status: ArenaRoundStatus;
    free: boolean | null;
    played: boolean;
    charged: string;
    payoutOrder: number | null;
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
    source: ArenaSource;
    round: number | null;
    tokenId: string | null;
    account: string | null;
    amount: string | null;
    ref: string | null;
    blockNumber: string;
    timestamp: string;
    txHash: string;
    logIndex: number;
}

export interface ArenaSkinPurchaseData {
    id: string;
    source: ArenaSource;
    purchaseId: string;
    tokenId: string;
    buyer: string;
    price: string;
    blockNumber: string;
    timestamp: string;
    txHash: string;
    logIndex: number;
}

export interface ArenaRecordRow {
    tokenId: string;
    pixelsWon: string;
    wins: number;
    roundsPlayed: number;
    lastRound: number | null;
    agentId: string | null;
    owner: string | null;
}

export type ArenaRecordSort = "pixels" | "wins" | "rounds";

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

export async function getArenaRoundPlayers(round: number, limit = 500, offset = 0): Promise<{
    round: number;
    status: ArenaRoundStatus;
    total: number;
    players: ArenaRoundPlayerData[];
    hasMore: boolean;
} | null> {
    return orNull(ponderFetch(`/arena/rounds/${round}/players?${page(limit, offset).toString()}`));
}

export async function getArenaRoundWinners(round: number, limit = 500, offset = 0): Promise<{
    round: number;
    status: ArenaRoundStatus;
    pool: string;
    prizes: string;
    total: number;
    winners: ArenaRoundPlayerData[];
    hasMore: boolean;
} | null> {
    return orNull(ponderFetch(`/arena/rounds/${round}/winners?${page(limit, offset).toString()}`));
}

export async function getArenaRoundRefunds(round: number, limit = 500, offset = 0): Promise<{
    round: number;
    status: ArenaRoundStatus;
    price: string | null;
    refunds: string;
    total: number;
    refundees: ArenaRoundPlayerData[];
    hasMore: boolean;
} | null> {
    return orNull(ponderFetch(`/arena/rounds/${round}/refunds?${page(limit, offset).toString()}`));
}

export async function getArenaRegistered(state: ArenaRegisteredState = "all", limit = 100, offset = 0): Promise<{
    state: ArenaRegisteredState;
    total: number;
    normies: ArenaRegisteredEntry[];
    hasMore: boolean;
}> {
    const params = page(limit, offset);
    params.set("state", state);
    return ponderFetch(`/arena/registered?${params.toString()}`);
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
    registered: number;
    active: number;
    short: number;
    normies: ArenaNormieData[];
}> {
    return ponderFetch(`/arena/holder/${address.toLowerCase()}`);
}

export async function getArenaActivity(opts: {
    kind?: string;
    source?: string;
    round?: number;
    tokenId?: number;
    address?: string;
    limit?: number;
    offset?: number;
} = {}): Promise<{ events: ArenaEventData[]; hasMore: boolean }> {
    const params = page(opts.limit ?? 50, opts.offset ?? 0);
    if (opts.kind) params.set("kind", opts.kind);
    if (opts.source) params.set("source", opts.source);
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

export async function getArenaRecords(sort: ArenaRecordSort = "pixels", limit = 50, offset = 0): Promise<{
    sort: ArenaRecordSort;
    normies: ArenaRecordRow[];
    hasMore: boolean;
}> {
    const params = page(limit, offset);
    params.set("sort", sort);
    return ponderFetch(`/arena/records?${params.toString()}`);
}

import { hexToBytes } from "viem";
import { countPixels, decodeTraits } from "../lib/traits.js";
import { generatePersona } from "../lib/persona.js";
import { parseZombieAttributes } from "./zombie-data.js";
import { buildLivePersona } from "./persona-live.js";
import {
    getRaritySnapshot,
    type AgentBindingData,
    type RaritySnapshotData,
    type RaritySnapshotToken,
} from "./ponder-data.js";
import { getListingSnapshot, getListingsStatus, type RarityListing } from "./rarity-listings.js";
import { NORMIES_ADDRESS, RARITY_CACHE_TTL_MS } from "../config.js";

const TOTAL_SUPPLY = 10_000;
const HISTORICAL_RARITY_CACHE_MAX = 32;
const OPENSEA_ITEM_URL = `https://opensea.io/item/ethereum/${NORMIES_ADDRESS.toLowerCase()}`;

const THE100 = new Set([
    464, 9846, 9197, 8183, 5052, 6227, 7491, 6497, 2623, 9548, 7490, 2449, 6303, 2532, 513, 1384, 9852, 9879, 6143, 820,
    9155, 2286, 7413, 1879, 108, 455, 9999, 1932, 7627, 1188, 9239, 235, 3846, 6765, 9076, 3732, 1476, 7908, 7479, 8576,
    115, 5707, 5816, 9735, 9982, 2908, 9644, 7011, 5679, 7384, 1617, 8990, 4868, 117, 4358, 6241, 5665, 2006, 7976,
    8115, 8759, 7887, 133, 27, 6016, 9980, 7652, 2565, 6884, 1603, 1204, 4057, 9612, 7028, 1898, 4829, 1208, 6793,
    1370, 4354, 9445, 3123, 6309, 615, 7961, 8612, 6155, 3408, 8510, 3837, 999, 8362, 376, 4681, 3465, 9561, 8831,
    5010, 2060, 7374,
]);

export const RARITY_WEIGHTS: Record<string, number> = {
    Type: 1,
    Gender: 1,
    Age: 1,
    "Hair Style": 1,
    "Facial Feature": 1,
    Eyes: 1,
    Expression: 1,
    Accessory: 1,
    Level: 3,
    "Action Points": 3,
    "Pixel Count": 1,
    Customized: 1,
};

const VALUE_BASED_TRAITS = new Set(["Level", "Action Points"]);

export interface RarityAttribute {
    trait_type: string;
    value: string | number;
    display_type?: string;
}

export interface RarityBreakdown {
    trait_type: string;
    value: string | number;
    count: number;
    frequency: number;
    ic: number;
    weight: number;
    weighted: number;
}

export interface RarityToken {
    id: number;
    name: string;
    attributes: RarityAttribute[];
    traitBreakdown: RarityBreakdown[];
    rarityScore: number;
    rank: number;
    owner: string | null;
    awake?: true;
    agentName?: string;
    agentOrder?: number;
    agentTotal?: number;
}

export interface CollectionSnapshot {
    blockNumber?: string;
    historical?: boolean;
    tokens: RarityToken[];
    byId: Map<number, RarityToken>;
    traitIndex: Record<string, Record<string, number>>;
    burnedIds: Set<number>;
    directBurnCounts: Map<number, number>;
    recursiveBurnCounts: Map<number, number>;
    recursiveBurnHolders: {
        wallets: Array<{
            wallet: string;
            customizedTokensHeld: number;
            totalRecursiveBurnCount: number;
            totalDirectBurnCount: number;
            tokenIds: number[];
        }>;
    };
    updatedAt: number;
    agentTotal: number;
}

let collectionCache: { value: CollectionSnapshot; expiresAt: number } | null = null;
const historicalCollectionCache = new Map<string, { value: CollectionSnapshot; expiresAt: number }>();

export async function getRarityCollection(force = false): Promise<CollectionSnapshot> {
    if (!force && collectionCache && collectionCache.expiresAt > Date.now()) {
        return collectionCache.value;
    }

    const snapshot = await getRaritySnapshot(NORMIES_ADDRESS);
    const value = buildCollectionFromSnapshot(snapshot);
    collectionCache = { value, expiresAt: Date.now() + RARITY_CACHE_TTL_MS };
    return value;
}

export async function getHistoricalRarityCollection(blockNumber: bigint, force = false): Promise<CollectionSnapshot> {
    const key = blockNumber.toString();
    const cached = historicalCollectionCache.get(key);
    if (!force && cached && cached.expiresAt > Date.now()) {
        return cached.value;
    }

    const snapshot = await getRaritySnapshot(NORMIES_ADDRESS, key);
    const value = buildCollectionFromSnapshot(snapshot);
    historicalCollectionCache.set(key, { value, expiresAt: Date.now() + RARITY_CACHE_TTL_MS });
    while (historicalCollectionCache.size > HISTORICAL_RARITY_CACHE_MAX) {
        const oldestKey = historicalCollectionCache.keys().next().value;
        if (oldestKey === undefined) break;
        historicalCollectionCache.delete(oldestKey);
    }
    return value;
}

function buildCollectionFromSnapshot(snapshot: RaritySnapshotData): CollectionSnapshot {
    const burnedIds = new Set(snapshot.burnedTokenIds.map((id) => Number(id)).filter(Number.isFinite));
    const directBurnCounts = recordToNumberMap(snapshot.burnCounts.direct);
    const recursiveBurnCounts = recordToNumberMap(snapshot.burnCounts.recursive);
    const agents = buildAgentMaps(snapshot.agentBindings);

    const tokens = snapshot.tokens
        .filter((token) => {
            const tokenId = Number(token.tokenId);
            return Number.isInteger(tokenId) && tokenId >= 0 && tokenId < TOTAL_SUPPLY && !burnedIds.has(tokenId);
        })
        .map((token) => buildRarityToken(token, agents));

    calculateRarity(tokens);

    const byId = new Map<number, RarityToken>();
    for (const token of tokens) {
        byId.set(token.id, token);
        if (token.awake && agents.orderById.has(token.id)) {
            token.agentOrder = agents.orderById.get(token.id);
            token.agentTotal = agents.total;
        }
    }

    const value: CollectionSnapshot = {
        blockNumber: snapshot.blockNumber,
        historical: snapshot.historical,
        tokens,
        byId,
        traitIndex: buildTraitIndex(tokens),
        burnedIds,
        directBurnCounts,
        recursiveBurnCounts,
        recursiveBurnHolders: snapshot.recursiveBurnHolders,
        updatedAt: Date.now(),
        agentTotal: agents.total,
    };

    return value;
}

export async function listRarityNormies(params: URLSearchParams) {
    const collection = await getRarityCollection();
    return listRarityNormiesFromCollection(collection, params, true);
}

export async function listHistoricalRarityNormies(blockNumber: bigint, params: URLSearchParams) {
    const collection = await getHistoricalRarityCollection(blockNumber);
    return listRarityNormiesFromCollection(collection, params, false);
}

function listRarityNormiesFromCollection(
    collection: CollectionSnapshot,
    params: URLSearchParams,
    includeListings: boolean,
) {
    const listings = includeListings ? getListingSnapshot() : new Map<number, RarityListing>();
    const typeFloors = getTypeFloors(collection.tokens, listings);
    const floorPrice = getFloorPrice(listings);
    const { sort, order } = parseSort(params);

    let items = [...collection.tokens];
    const search = (params.get("search") ?? "").trim().toLowerCase();
    if (search) {
        items = items.filter((token) => String(token.id).includes(search) || token.name.toLowerCase().includes(search));
    }

    if (params.get("listed") === "1") items = items.filter((token) => listings.has(token.id));
    if (params.get("underpriced") === "1") {
        items = items.filter((token) => {
            const listing = listings.get(token.id);
            if (!listing) return false;
            const fair = getFairValue(token, collection, floorPrice, typeFloors);
            return fair !== null && listing.priceEth < fair;
        });
    }
    if (params.get("the100") === "1") items = items.filter((token) => THE100.has(token.id));
    if (params.get("awake") === "1") items = items.filter((token) => token.awake);

    const pxTier = params.get("px_tier");
    if (pxTier) {
        const tiers = pxTier.split(",");
        items = items.filter((token) => {
            const pixels = Number(attributeValue(token, "Pixel Count"));
            return tiers.some((tier) =>
                (tier === "low" && pixels <= 490) ||
                (tier === "mid" && pixels >= 491 && pixels <= 890) ||
                (tier === "high" && pixels >= 891),
            );
        });
    }

    const walletIds = params.get("wallet_ids");
    if (walletIds) {
        const ids = new Set(walletIds.split(",").map((id) => Number(id)).filter(Number.isInteger));
        items = items.filter((token) => ids.has(token.id));
    }

    items = applyTraitFilters(items, params);
    items.sort(sorter(sort, order, listings));

    const page = Math.max(1, Number(params.get("page") ?? 1) || 1);
    const limit = Math.min(100, Math.max(1, Number(params.get("limit") ?? 60) || 60));
    const total = items.length;
    const totalPages = Math.ceil(total / limit);
    const start = (page - 1) * limit;

    return {
        blockNumber: collection.blockNumber,
        historical: collection.historical,
        items: items.slice(start, start + limit).map((token) => slimToken(token, collection, listings, floorPrice, typeFloors)),
        total,
        page,
        limit,
        totalPages,
        floorPrice,
        typeFloors,
    };
}

export async function getRarityNormie(tokenId: number) {
    const collection = await getRarityCollection();
    if (collection.burnedIds.has(tokenId)) return { status: 410 as const, body: { error: "Token is burned" } };

    const token = collection.byId.get(tokenId);
    if (!token) return { status: 404 as const, body: { error: "Not indexed yet" } };

    const listings = getListingSnapshot();
    const typeFloors = getTypeFloors(collection.tokens, listings);
    const floorPrice = getFloorPrice(listings);
    return { status: 200 as const, body: detailToken(token, collection, listings, floorPrice, typeFloors) };
}

export async function getHistoricalRarityNormie(blockNumber: bigint, tokenId: number) {
    const collection = await getHistoricalRarityCollection(blockNumber);
    if (collection.burnedIds.has(tokenId)) {
        return {
            status: 410 as const,
            body: { error: "Token was burned at this block", blockNumber: collection.blockNumber, historical: true },
        };
    }

    const token = collection.byId.get(tokenId);
    if (!token) {
        return {
            status: 404 as const,
            body: { error: "Not indexed at this block", blockNumber: collection.blockNumber, historical: true },
        };
    }

    const listings = new Map<number, RarityListing>();
    return {
        status: 200 as const,
        body: detailToken(token, collection, listings, null, {}),
    };
}

export async function refreshRarityNormie(tokenId: number) {
    await getRarityCollection(true);
    return getRarityNormie(tokenId);
}

export async function getRarityPersona(tokenId: number) {
    const collection = await getRarityCollection();
    const token = collection.byId.get(tokenId);
    if (!token?.awake) return { status: 404 as const, body: { error: "Not an awake agent" } };

    const persona = await buildLivePersona(tokenId);
    return {
        status: 200 as const,
        body: {
            tokenId: String(tokenId),
            name: persona.name,
            type: persona.type,
            tagline: persona.tagline,
            backstory: persona.backstory,
            greeting: persona.greeting,
            personalityTraits: persona.personalityTraits,
            communicationStyle: persona.communicationStyle,
            quirks: persona.quirks,
            systemPrompt: persona.systemPrompt,
            agentOrder: token.agentOrder,
            agentTotal: token.agentTotal,
        },
    };
}

export async function getRarityTraits() {
    const collection = await getRarityCollection();
    return traitsFromCollection(collection);
}

export async function getHistoricalRarityTraits(blockNumber: bigint) {
    const collection = await getHistoricalRarityCollection(blockNumber);
    return {
        blockNumber: collection.blockNumber,
        historical: true,
        traits: traitsFromCollection(collection),
    };
}

function traitsFromCollection(collection: CollectionSnapshot) {
    const result: Record<string, Array<{ value: string; count: number }>> = {};
    for (const [traitType, values] of Object.entries(collection.traitIndex)) {
        result[traitType] = Object.entries(values)
            .map(([value, count]) => ({ value, count }))
            .sort((a, b) => b.count - a.count);
    }
    return result;
}

export async function getRarityStats() {
    const collection = await getRarityCollection();
    const listingStatus = getListingsStatus();
    const live = TOTAL_SUPPLY - collection.burnedIds.size;
    return {
        fetched: collection.tokens.length,
        total: live,
        burned: collection.burnedIds.size,
        supply: TOTAL_SUPPLY,
        progress: live > 0 ? Math.round((collection.tokens.length / live) * 10_000) / 100 : 0,
        running: false,
        lastSaved: new Date(collection.updatedAt).toISOString(),
        weights: RARITY_WEIGHTS,
        listed: listingStatus.listed,
        openseaConnected: listingStatus.openseaConnected,
        floorPrice: listingStatus.floorPrice,
        awake: collection.agentTotal,
    };
}

export async function getHistoricalRarityStats(blockNumber: bigint) {
    const collection = await getHistoricalRarityCollection(blockNumber);
    const live = TOTAL_SUPPLY - collection.burnedIds.size;
    return {
        blockNumber: collection.blockNumber,
        historical: true,
        fetched: collection.tokens.length,
        total: live,
        burned: collection.burnedIds.size,
        supply: TOTAL_SUPPLY,
        progress: live > 0 ? Math.round((collection.tokens.length / live) * 10_000) / 100 : 0,
        running: false,
        lastSaved: new Date(collection.updatedAt).toISOString(),
        weights: RARITY_WEIGHTS,
        listed: 0,
        openseaConnected: false,
        floorPrice: null,
        awake: collection.agentTotal,
    };
}

export async function getRarityHolder(address: string) {
    const collection = await getRarityCollection();
    const normalized = address.toLowerCase();
    const tokenIds = collection.tokens
        .filter((token) => token.owner?.toLowerCase() === normalized)
        .map((token) => token.id)
        .sort((a, b) => a - b);
    return { address: normalized, tokenIds };
}

export async function getHistoricalRarityHolder(blockNumber: bigint, address: string) {
    const collection = await getHistoricalRarityCollection(blockNumber);
    const normalized = address.toLowerCase();
    const tokenIds = collection.tokens
        .filter((token) => token.owner?.toLowerCase() === normalized)
        .map((token) => token.id)
        .sort((a, b) => a - b);
    return { blockNumber: collection.blockNumber, historical: true, address: normalized, tokenIds };
}

export async function getRecursiveBurnHolders(limit: number, wallet?: string) {
    const collection = await getRarityCollection();
    return recursiveBurnHoldersFromCollection(collection, limit, wallet);
}

export async function getHistoricalRecursiveBurnHolders(blockNumber: bigint, limit: number, wallet?: string) {
    const collection = await getHistoricalRarityCollection(blockNumber);
    return recursiveBurnHoldersFromCollection(collection, limit, wallet);
}

function recursiveBurnHoldersFromCollection(collection: CollectionSnapshot, limit: number, wallet?: string) {
    if (wallet) {
        const entry = collection.recursiveBurnHolders.wallets.find((item) => item.wallet === wallet.toLowerCase()) ?? null;
        return { blockNumber: collection.blockNumber, historical: collection.historical, updatedAt: collection.updatedAt, wallet: entry };
    }
    return {
        blockNumber: collection.blockNumber,
        historical: collection.historical,
        updatedAt: collection.updatedAt,
        totalWallets: collection.recursiveBurnHolders.wallets.length,
        items: collection.recursiveBurnHolders.wallets.slice(0, limit),
    };
}

function buildRarityToken(token: RaritySnapshotToken, agents: ReturnType<typeof buildAgentMaps>): RarityToken {
    const tokenId = Number(token.tokenId);
    const original = decodeTraits(token.traitsHex).attributes;
    const identityRecord = attributesToRecord(original);
    const canvasInfo = canvasSummary(token);
    const attributes = activeBaseAttributes(token, original);

    attributes.push({ display_type: "number", trait_type: "Level", value: canvasInfo.level });
    if (token.legendaryCanvas?.isLegendary && token.legendaryCanvas.artistName) {
        attributes.push({ trait_type: "Legendary Canvas", value: token.legendaryCanvas.artistName });
    }
    attributes.push({ display_type: "number", trait_type: "Pixel Count", value: displayPixelCount(token) });
    attributes.push({ display_type: "number", trait_type: "Action Points", value: canvasInfo.actionPoints });
    attributes.push({ trait_type: "Customized", value: canvasInfo.customized ? "Yes" : "No" });

    const agent = agents.byId.get(tokenId);
    const rarityToken: RarityToken = {
        id: tokenId,
        name: `Normie #${tokenId}`,
        attributes,
        traitBreakdown: [],
        rarityScore: 0,
        rank: 0,
        owner: token.owner,
    };

    if (agent) {
        const persona = generatePersona(
            BigInt(tokenId),
            { attributes: identityRecord },
            { customized: false, level: 1, actionPoints: 0, transformationCount: 0 },
            null,
            [],
        );
        rarityToken.awake = true;
        rarityToken.agentName = persona.name;
    }

    return rarityToken;
}

function activeBaseAttributes(token: RaritySnapshotToken, original: RarityAttribute[]): RarityAttribute[] {
    if (token.zombie?.isZombie && token.zombie.attributesJson) {
        try {
            return parseZombieAttributes(token.zombie.attributesJson);
        } catch {
            return [...original];
        }
    }
    return [...original];
}

function canvasSummary(token: RaritySnapshotToken): { actionPoints: number; level: number; customized: boolean } {
    const actionPoints = token.canvas ? Number(BigInt(token.canvas.actionPoints)) : 0;
    return {
        actionPoints,
        level: Math.floor(actionPoints / 10) + 1,
        customized: token.canvas?.customized ?? false,
    };
}

function displayPixelCount(token: RaritySnapshotToken): number {
    if (typeof token.displayPixelCount === "number" && Number.isFinite(token.displayPixelCount)) {
        return token.displayPixelCount;
    }

    // Pixel Count is a rarity trait derived from the ORIGINAL minted bitmap.
    // Canvas customizations (latestTransformBitmap) must NOT be composited in:
    // editing a Normie never changes its rarity-relevant pixel count, and doing
    // so also distorts the collection-wide pixel-count distribution (and thus
    // every token's score). Zombies use their zombie base bitmap, also uncomposited.
    if (token.zombie?.isZombie && token.zombie.bitmap) {
        return countPixels(hexToBytes(token.zombie.bitmap));
    }
    return countPixels(hexToBytes(token.rawImageData));
}

function buildAgentMaps(bindings: AgentBindingData[]) {
    const sorted = [...bindings].sort((a, b) => Number(BigInt(a.timestamp) - BigInt(b.timestamp)) || Number(BigInt(a.tokenId) - BigInt(b.tokenId)));
    const byId = new Map<number, AgentBindingData>();
    const orderById = new Map<number, number>();
    sorted.forEach((binding, index) => {
        const tokenId = Number(binding.tokenId);
        if (!Number.isInteger(tokenId)) return;
        byId.set(tokenId, binding);
        orderById.set(tokenId, index + 1);
    });
    return { byId, orderById, total: byId.size };
}

function calculateRarity(tokens: RarityToken[]): void {
    if (tokens.length === 0) return;

    const total = tokens.length;
    const counts = buildTraitIndex(tokens);
    const numericMax: Record<string, number> = {};
    const numericMin: Record<string, number> = {};

    for (const token of tokens) {
        for (const attr of token.attributes) {
            const traitType = attr.trait_type;
            if (!VALUE_BASED_TRAITS.has(traitType)) continue;
            const num = Number(attr.value);
            if (Number.isNaN(num)) continue;
            numericMax[traitType] = Math.max(numericMax[traitType] ?? -Infinity, num);
            numericMin[traitType] = Math.min(numericMin[traitType] ?? Infinity, num);
        }
    }

    const maxIC = Math.log2(total);
    for (const token of tokens) {
        let score = 0;
        const breakdown: RarityBreakdown[] = [];
        for (const attr of token.attributes) {
            const traitType = attr.trait_type;
            const value = String(attr.value);
            const count = counts[traitType]?.[value] ?? 0;
            const frequency = count / total;
            const weight = RARITY_WEIGHTS[traitType] ?? 1;

            let ic: number;
            if (VALUE_BASED_TRAITS.has(traitType) && numericMax[traitType] !== undefined) {
                const num = Number(attr.value);
                const range = numericMax[traitType] - numericMin[traitType];
                const normalized = range > 0 ? (num - numericMin[traitType]) / range : 1;
                ic = normalized * maxIC;
            } else {
                ic = -Math.log2(frequency);
            }
            const weighted = ic * weight;
            score += weighted;
            breakdown.push({
                trait_type: traitType,
                value: attr.value,
                count,
                frequency: Math.round(frequency * 10_000) / 100,
                ic: Math.round(ic * 100) / 100,
                weight,
                weighted: Math.round(weighted * 100) / 100,
            });
        }
        token.rarityScore = Math.round(score * 100) / 100;
        token.traitBreakdown = breakdown;
    }

    tokens.sort((a, b) => b.rarityScore - a.rarityScore);
    tokens.forEach((token, index) => {
        token.rank = index + 1;
    });
}

function buildTraitIndex(tokens: RarityToken[]): Record<string, Record<string, number>> {
    const counts: Record<string, Record<string, number>> = {};
    for (const token of tokens) {
        for (const attr of token.attributes) {
            const traitType = attr.trait_type;
            const value = String(attr.value);
            counts[traitType] ??= {};
            counts[traitType][value] = (counts[traitType][value] ?? 0) + 1;
        }
    }
    return counts;
}

function attributesToRecord(attributes: RarityAttribute[]): Record<string, string> {
    const record: Record<string, string> = {};
    for (const attr of attributes) record[attr.trait_type] = String(attr.value);
    return record;
}

function recordToNumberMap(record: Record<string, number>): Map<number, number> {
    const map = new Map<number, number>();
    for (const [tokenId, count] of Object.entries(record)) {
        const id = Number(tokenId);
        if (Number.isInteger(id)) map.set(id, count);
    }
    return map;
}

function parseSort(params: URLSearchParams): { sort: string; order: 1 | -1 } {
    const raw = params.get("sort") ?? "rank";
    const [sort, inlineOrder] = raw.split("|");
    const orderRaw = inlineOrder ?? params.get("order") ?? "asc";
    return { sort: sort || "rank", order: orderRaw === "desc" ? -1 : 1 };
}

function applyTraitFilters(tokens: RarityToken[], params: URLSearchParams): RarityToken[] {
    let items = tokens;
    for (const [key, val] of params.entries()) {
        if (!val) continue;
        if (key.startsWith("trait_") && key.endsWith("_min")) {
            const traitType = key.slice(6, -4).replace(/_/g, " ");
            const minVal = Number.parseFloat(val);
            items = items.filter((token) => Number(attributeValue(token, traitType)) >= minVal);
        } else if (key.startsWith("trait_") && key.endsWith("_max")) {
            const traitType = key.slice(6, -4).replace(/_/g, " ");
            const maxVal = Number.parseFloat(val);
            items = items.filter((token) => Number(attributeValue(token, traitType)) <= maxVal);
        } else if (key.startsWith("trait_")) {
            const traitType = key.slice(6).replace(/_/g, " ");
            const allowed = val.split(",").map((item) => item.trim());
            items = items.filter((token) => {
                const attr = attributeValue(token, traitType);
                return attr !== undefined && allowed.includes(String(attr));
            });
        }
    }
    return items;
}

function sorter(sort: string, order: 1 | -1, listings: Map<number, RarityListing>) {
    const getAttr = (token: RarityToken, trait: string) => Number(attributeValue(token, trait)) || 0;
    const getPrice = (token: RarityToken) => {
        const price = listings.get(token.id)?.priceEth;
        return typeof price === "number" && Number.isFinite(price) ? price : Infinity;
    };
    const safeCmp = (a: number, b: number) => {
        if (a === b) return 0;
        if (!Number.isFinite(a)) return 1;
        if (!Number.isFinite(b)) return -1;
        return a - b;
    };
    return (a: RarityToken, b: RarityToken) => {
        if (sort === "id") return (a.id - b.id) * order;
        if (sort === "score") return (a.rarityScore - b.rarityScore) * order;
        if (sort === "level") return (getAttr(a, "Level") - getAttr(b, "Level")) * order;
        if (sort === "action_points") return (getAttr(a, "Action Points") - getAttr(b, "Action Points")) * order;
        if (sort === "pixel_count") return (getAttr(a, "Pixel Count") - getAttr(b, "Pixel Count")) * order;
        if (sort === "price") return safeCmp(getPrice(a), getPrice(b)) * order || a.rank - b.rank;
        if (sort === "awake_registered") return ((a.agentOrder ?? 0) - (b.agentOrder ?? 0)) * order || a.rank - b.rank;
        return (a.rank - b.rank) * order;
    };
}

function attributeValue(token: RarityToken, traitType: string): string | number | undefined {
    return token.attributes.find((attr) => attr.trait_type.toLowerCase() === traitType.toLowerCase())?.value;
}

function getFloorPrice(listings: Map<number, RarityListing>): number | null {
    let min = Infinity;
    for (const listing of listings.values()) {
        if (Number.isFinite(listing.priceEth) && listing.priceEth < min) min = listing.priceEth;
    }
    return Number.isFinite(min) ? min : null;
}

function getTypeFloors(tokens: RarityToken[], listings: Map<number, RarityListing>): Record<string, number> {
    const floors: Record<string, number> = {};
    const byId = new Map(tokens.map((token) => [token.id, token]));
    for (const [tokenId, listing] of listings) {
        const token = byId.get(tokenId);
        if (!token) continue;
        const type = attributeValue(token, "Type");
        if (!type) continue;
        const key = String(type);
        if (!floors[key] || listing.priceEth < floors[key]) floors[key] = listing.priceEth;
    }
    return floors;
}

function getFairValue(
    token: RarityToken,
    collection: CollectionSnapshot,
    floorPrice: number | null,
    typeFloors: Record<string, number>,
): number | null {
    if (!floorPrice) return null;
    const burnCount = collection.recursiveBurnCounts.get(token.id) ?? 0;
    const type = attributeValue(token, "Type");
    const typeFloor = type ? typeFloors[String(type)] ?? 0 : 0;
    if (burnCount <= 0 && !typeFloor) return null;
    return Math.round((burnCount * floorPrice + typeFloor) * 10_000) / 10_000;
}

function slimToken(
    token: RarityToken,
    collection: CollectionSnapshot,
    listings: Map<number, RarityListing>,
    floorPrice: number | null,
    typeFloors: Record<string, number>,
) {
    const item: Record<string, unknown> = {
        id: token.id,
        name: token.name,
        rank: token.rank,
        rarityScore: token.rarityScore,
        attributes: token.attributes,
    };
    const listing = listings.get(token.id);
    if (listing) item.listing = listing;
    const burnCount = collection.recursiveBurnCounts.get(token.id) ?? 0;
    if (burnCount > 0) item.burnCount = burnCount;
    const fairValue = getFairValue(token, collection, floorPrice, typeFloors);
    if (fairValue !== null) item.fairValue = fairValue;
    if (listing && fairValue !== null) item.underpriced = listing.priceEth < fairValue;
    if (token.awake) {
        item.awake = true;
        if (token.agentName) item.agentName = token.agentName;
    }
    return item;
}

function detailToken(
    token: RarityToken,
    collection: CollectionSnapshot,
    listings: Map<number, RarityListing>,
    floorPrice: number | null,
    typeFloors: Record<string, number>,
) {
    const item = {
        ...token,
        openseaUrl: `${OPENSEA_ITEM_URL}/${token.id}`,
    } as Record<string, unknown>;
    if (collection.blockNumber) item.blockNumber = collection.blockNumber;
    if (collection.historical) item.historical = true;
    const listing = listings.get(token.id);
    if (listing) item.listing = listing;
    const burnCount = collection.recursiveBurnCounts.get(token.id) ?? 0;
    if (burnCount > 0) item.burnCount = burnCount;
    const directBurnCount = collection.directBurnCounts.get(token.id) ?? 0;
    if (directBurnCount > 0) item.directBurnCount = directBurnCount;
    const type = attributeValue(token, "Type");
    if (type && typeFloors[String(type)]) item.typeFloor = typeFloors[String(type)];
    const fairValue = getFairValue(token, collection, floorPrice, typeFloors);
    if (fairValue !== null) item.fairValue = fairValue;
    if (listing && fairValue !== null) item.underpriced = listing.priceEth < fairValue;
    return item;
}

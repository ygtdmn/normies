import { Hono } from "hono";
import { parseTokenId, queryInt } from "../lib/validation.js";
import { ARENA_ENABLED } from "../config.js";
import {
    getArenaActivity,
    getArenaHolder,
    getArenaNormie,
    getArenaNormieRounds,
    getArenaNormieSkins,
    getArenaRecords,
    getArenaRegistered,
    getArenaRound,
    getArenaRoundPlayers,
    getArenaRoundRefunds,
    getArenaRounds,
    getArenaRoundWinners,
    getArenaSkins,
    getArenaStatus,
    type ArenaRecordSort,
    type ArenaRegisteredState,
    type ArenaRoundStatus,
} from "../services/arena-data.js";

const arena = new Hono();

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const ROUND_STATUSES: Array<ArenaRoundStatus | "all"> = ["all", "upcoming", "open", "ended", "cancelled"];
const REGISTERED_STATES: ArenaRegisteredState[] = ["all", "active", "short"];
const RECORD_SORTS: ArenaRecordSort[] = ["pixels", "wins", "rounds"];
const EVENT_KINDS = [
    "deposit",
    "withdraw",
    "rescue",
    "prize",
    "refund",
    "sponsor",
    "sponsorship-moved",
    "sponsorship-released",
    "registered",
    "cleared",
    "agent-linked",
    "skin",
    "purchases-imported",
    "migrated",
    "round-started",
    "round-ended",
    "round-cancelled",
];
const SOURCES = ["v2", "v3"];

type Query = { req: { query: (key: string) => string | undefined } };

function parsePagination(c: Query, fallback = 50, max = 100) {
    const limit = queryInt(c.req.query("limit"), fallback, 1, max);
    const offset = queryInt(c.req.query("offset"), 0, 0);
    return { limit, offset };
}

/** Rounds are numbered from 1. */
function parseRound(raw: string): number | undefined {
    if (!/^\d{1,9}$/.test(raw)) return undefined;
    const round = Number(raw);
    return round > 0 ? round : undefined;
}

arena.use("*", async (c, next) => {
    if (!ARENA_ENABLED) return c.json({ error: "Arena features are not enabled" }, 404);
    await next();
});

arena.get("/status", async (c) => {
    return c.json(await getArenaStatus());
});

arena.get("/rounds", async (c) => {
    const { limit, offset } = parsePagination(c);
    const status = c.req.query("status") ?? "all";
    if (!ROUND_STATUSES.includes(status as ArenaRoundStatus | "all")) {
        return c.json({ error: `status must be one of ${ROUND_STATUSES.join(", ")}` }, 400);
    }
    const sort = c.req.query("sort") === "asc" ? "asc" : "desc";
    return c.json(await getArenaRounds({ status: status as ArenaRoundStatus | "all", sort, limit, offset }));
});

arena.get("/rounds/:round", async (c) => {
    const round = parseRound(c.req.param("round"));
    if (round === undefined) return c.json({ error: "Invalid round" }, 400);
    const data = await getArenaRound(round);
    return data ? c.json(data) : c.json({ error: "Round not found" }, 404);
});

// A round can hold every registered Normie, so these lists page up to 1000 at a time.
arena.get("/rounds/:round/players", async (c) => {
    const round = parseRound(c.req.param("round"));
    if (round === undefined) return c.json({ error: "Invalid round" }, 400);
    const { limit, offset } = parsePagination(c, 500, 1000);
    const data = await getArenaRoundPlayers(round, limit, offset);
    return data ? c.json(data) : c.json({ error: "Round not found" }, 404);
});

arena.get("/rounds/:round/winners", async (c) => {
    const round = parseRound(c.req.param("round"));
    if (round === undefined) return c.json({ error: "Invalid round" }, 400);
    const { limit, offset } = parsePagination(c, 500, 1000);
    const data = await getArenaRoundWinners(round, limit, offset);
    return data ? c.json(data) : c.json({ error: "Round not found" }, 404);
});

arena.get("/rounds/:round/refunds", async (c) => {
    const round = parseRound(c.req.param("round"));
    if (round === undefined) return c.json({ error: "Invalid round" }, 400);
    const { limit, offset } = parsePagination(c, 500, 1000);
    const data = await getArenaRoundRefunds(round, limit, offset);
    return data ? c.json(data) : c.json({ error: "Round not found" }, 404);
});

arena.get("/registered", async (c) => {
    const { limit, offset } = parsePagination(c, 100, 1000);
    const state = c.req.query("state") ?? "all";
    if (!REGISTERED_STATES.includes(state as ArenaRegisteredState)) {
        return c.json({ error: `state must be one of ${REGISTERED_STATES.join(", ")}` }, 400);
    }
    return c.json(await getArenaRegistered(state as ArenaRegisteredState, limit, offset));
});

arena.get("/normie/:id", async (c) => {
    const parsed = parseTokenId(c.req.param("id"));
    if ("error" in parsed) return c.json({ error: parsed.error }, 400);
    return c.json(await getArenaNormie(parsed.tokenId));
});

arena.get("/normie/:id/rounds", async (c) => {
    const parsed = parseTokenId(c.req.param("id"));
    if ("error" in parsed) return c.json({ error: parsed.error }, 400);
    const { limit, offset } = parsePagination(c);
    return c.json(await getArenaNormieRounds(parsed.tokenId, limit, offset));
});

arena.get("/normie/:id/activity", async (c) => {
    const parsed = parseTokenId(c.req.param("id"));
    if ("error" in parsed) return c.json({ error: parsed.error }, 400);
    const { limit, offset } = parsePagination(c);
    return c.json(await getArenaActivity({ tokenId: parsed.tokenId, limit, offset }));
});

arena.get("/holder/:address", async (c) => {
    const address = c.req.param("address");
    if (!ADDRESS_RE.test(address)) return c.json({ error: "Invalid Ethereum address" }, 400);
    return c.json(await getArenaHolder(address));
});

arena.get("/activity", async (c) => {
    const { limit, offset } = parsePagination(c);
    const kind = c.req.query("kind");
    if (kind !== undefined && !EVENT_KINDS.includes(kind)) {
        return c.json({ error: `kind must be one of ${EVENT_KINDS.join(", ")}` }, 400);
    }
    const source = c.req.query("source");
    if (source !== undefined && !SOURCES.includes(source)) {
        return c.json({ error: `source must be one of ${SOURCES.join(", ")}` }, 400);
    }
    const roundRaw = c.req.query("round");
    const round = roundRaw === undefined ? undefined : parseRound(roundRaw);
    if (roundRaw !== undefined && round === undefined) return c.json({ error: "Invalid round" }, 400);
    const tokenRaw = c.req.query("tokenId");
    let tokenId: number | undefined;
    if (tokenRaw !== undefined) {
        const parsed = parseTokenId(tokenRaw);
        if ("error" in parsed) return c.json({ error: parsed.error }, 400);
        tokenId = parsed.tokenId;
    }
    const address = c.req.query("address");
    if (address !== undefined && !ADDRESS_RE.test(address)) return c.json({ error: "Invalid Ethereum address" }, 400);
    return c.json(await getArenaActivity({ kind, source, round, tokenId, address, limit, offset }));
});

arena.get("/skins", async (c) => {
    const { limit, offset } = parsePagination(c);
    const buyer = c.req.query("buyer");
    if (buyer !== undefined && !ADDRESS_RE.test(buyer)) return c.json({ error: "Invalid buyer" }, 400);
    return c.json(await getArenaSkins({ buyer, limit, offset }));
});

arena.get("/skins/normie/:id", async (c) => {
    const parsed = parseTokenId(c.req.param("id"));
    if ("error" in parsed) return c.json({ error: parsed.error }, 400);
    return c.json(await getArenaNormieSkins(parsed.tokenId));
});

arena.get("/records", async (c) => {
    const { limit, offset } = parsePagination(c);
    const sort = c.req.query("sort") ?? "pixels";
    if (!RECORD_SORTS.includes(sort as ArenaRecordSort)) {
        return c.json({ error: `sort must be one of ${RECORD_SORTS.join(", ")}` }, 400);
    }
    return c.json(await getArenaRecords(sort as ArenaRecordSort, limit, offset));
});

export { arena };

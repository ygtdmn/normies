import { timingSafeEqual } from "node:crypto";
import type { Context, MiddlewareHandler } from "hono";
import {
    INTERNAL_KEYS,
    RATE_LIMIT_MAX_REQUESTS,
    RATE_LIMIT_MODE,
    RATE_LIMIT_WINDOW_MS,
    type RateLimitMode,
} from "../config.js";
import {
    TIERS,
    TokenBuckets,
    clientAddress,
    costOf,
    tierOf,
    type Decision,
    type Tier,
} from "../lib/rate-policy.js";

/**
 * The API's rate limiter. RATE_LIMIT_MODE picks who decides (see config.ts): the old sliding
 * window, the tiered token buckets, or the window while the buckets watch ("shadow").
 *
 * Rate headers are dropped from responses Cloudflare may cache: a cached copy would repeat one
 * caller's remaining count to everyone else.
 */

export interface RateLimiterOptions {
    mode: RateLimitMode;
    /** secret -> service name */
    keys: ReadonlyMap<string, string>;
    legacyMax: number;
    legacyWindowMs: number;
    now?: () => number;
    sleep?: (ms: number) => Promise<void>;
    /** How often the summary is logged and the period's counters reset. 0 = never (tests). */
    reportEveryMs?: number;
    log?: (line: string) => void;
}

export interface RateLimiter {
    middleware: MiddlewareHandler;
    /** The service name for a valid internal key, else null. */
    keyName(secret: string | undefined): string | null;
    snapshot(): RateLimitSnapshot;
}

interface TierCounters {
    requests: number;
    tokens: number;
    held: number;
    rejected: number;
}

export interface RateLimitSnapshot {
    mode: RateLimitMode;
    since: string;
    /** What the token buckets did (enforce) or would have done (shadow). */
    tiers: Record<Tier, TierCounters>;
    internalKeys: Record<string, { requests: number; tokens: number; rejected: number }>;
    /** Callers the buckets rejected most this period, excluding internal keys. */
    topRejected: { client: string; tier: Tier; rejected: number }[];
    /** 429s the legacy window sent this period (legacy and shadow modes). */
    legacyRejected: number;
    /**
     * What each internal key, and each other tier as a whole, asked for most this period, by
     * tokens. Ids, addresses and names in a path are folded (`/normie/:n/image.svg`), so one
     * route is one row. `errors` counts the route's own 4xx and 5xx answers, not 429s.
     */
    topPaths: Record<string, PathCount[]>;
    buckets: number;
    policies: typeof TIERS;
}

/** Header edits after next(), tolerating a response whose headers are immutable. */
function editHeaders(c: Context, edit: (headers: Headers) => void) {
    try {
        edit(c.res.headers);
    } catch {
        /* an upstream Response passed through as is: leave it alone */
    }
}

const RATE_HEADERS = [
    "X-RateLimit-Limit",
    "X-RateLimit-Remaining",
    "RateLimit-Limit",
    "RateLimit-Remaining",
    "RateLimit-Reset",
];

function isEdgeCacheable(cacheControl: string | null): boolean {
    if (!cacheControl || !/\bpublic\b/.test(cacheControl)) return false;
    const sMaxAge = /s-maxage=(\d+)/.exec(cacheControl);
    return sMaxAge !== null && Number(sMaxAge[1]) > 0;
}

export interface PathCount {
    path: string;
    requests: number;
    tokens: number;
    errors: number;
}

/** Distinct route shapes kept per caller group per period; the rest count as "(other)". */
const MAX_SHAPES = 300;

/** A path with its ids folded: numbers, 0x addresses and hashes, ENS names, burn ids like 2-6. */
export function routeShape(path: string): string {
    return path
        .split("/")
        .map((part) => {
            if (/^\d+$/.test(part)) return ":n";
            if (/^\d+-\d+$/.test(part)) return ":n-:n";
            if (/^0x[0-9a-fA-F]+$/.test(part)) return ":hex";
            if (/\.eth$/i.test(part)) return ":ens";
            if (/^\d+\.(svg|png|json)$/.test(part)) return ":n." + part.split(".").pop();
            return part;
        })
        .join("/");
}

function emptyCounters(): Record<Tier, TierCounters> {
    const zero = (): TierCounters => ({ requests: 0, tokens: 0, held: 0, rejected: 0 });
    return { internal: zero(), website: zero(), public: zero(), crawler: zero() };
}

export function createRateLimiter(options: RateLimiterOptions): RateLimiter {
    const now = options.now ?? Date.now;
    const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
    const log = options.log ?? ((line: string) => console.log(line));
    const buckets = new TokenBuckets(now);
    const window = new Map<string, number[]>();
    const keyBuffers = [...options.keys].map(([secret, name]) => ({ buffer: Buffer.from(secret), name }));

    let since = now();
    let tiers = emptyCounters();
    let internalKeys = new Map<string, { requests: number; tokens: number; rejected: number }>();
    let rejectedBy = new Map<string, { tier: Tier; rejected: number }>();
    let legacyRejected = 0;
    let paths = new Map<string, Map<string, PathCount>>();

    /** The row for this group and route this period, created on first use. */
    function pathRow(group: string, path: string): PathCount {
        let rows = paths.get(group);
        if (!rows) {
            rows = new Map();
            paths.set(group, rows);
        }
        let shape = routeShape(path);
        if (!rows.has(shape) && rows.size >= MAX_SHAPES) shape = "(other)";
        let row = rows.get(shape);
        if (!row) {
            row = { path: shape, requests: 0, tokens: 0, errors: 0 };
            rows.set(shape, row);
        }
        return row;
    }

    function keyName(secret: string | undefined): string | null {
        if (!secret) return null;
        const given = Buffer.from(secret);
        for (const key of keyBuffers) {
            if (key.buffer.length === given.length && timingSafeEqual(key.buffer, given)) return key.name;
        }
        return null;
    }

    function record(tier: Tier, who: string, decision: Decision, cost: number) {
        const t = tiers[tier];
        t.requests += 1;
        t.tokens += cost;
        if (decision.action === "hold") t.held += 1;
        if (decision.action === "reject") t.rejected += 1;
        if (tier === "internal") {
            const k = internalKeys.get(who) ?? { requests: 0, tokens: 0, rejected: 0 };
            k.requests += 1;
            k.tokens += cost;
            if (decision.action === "reject") k.rejected += 1;
            internalKeys.set(who, k);
        } else if (decision.action === "reject" && (rejectedBy.has(who) || rejectedBy.size < 5_000)) {
            const r = rejectedBy.get(who) ?? { tier, rejected: 0 };
            r.rejected += 1;
            rejectedBy.set(who, r);
        }
    }

    function snapshot(): RateLimitSnapshot {
        return {
            mode: options.mode,
            since: new Date(since).toISOString(),
            tiers: structuredClone(tiers),
            internalKeys: Object.fromEntries(internalKeys),
            topRejected: [...rejectedBy]
                .sort((a, b) => b[1].rejected - a[1].rejected)
                .slice(0, 15)
                .map(([client, r]) => ({ client, tier: r.tier, rejected: r.rejected })),
            legacyRejected,
            topPaths: Object.fromEntries(
                [...paths].map(([group, rows]) => [
                    group,
                    [...rows.values()].sort((a, b) => b.tokens - a.tokens).slice(0, 15).map((row) => ({ ...row })),
                ]),
            ),
            buckets: buckets.size,
            policies: TIERS,
        };
    }

    if (options.reportEveryMs) {
        setInterval(() => {
            if (options.mode !== "legacy") log(`[rate-limit] ${JSON.stringify(snapshot())}`);
            since = now();
            tiers = emptyCounters();
            internalKeys = new Map();
            rejectedBy = new Map();
            legacyRejected = 0;
            paths = new Map();
            buckets.prune((id) => TIERS[id.slice(0, id.indexOf(":")) as Tier] ?? TIERS.public);
            const cutoff = now() - options.legacyWindowMs;
            for (const [client, stamps] of window) if (!stamps.some((t) => t >= cutoff)) window.delete(client);
        }, options.reportEveryMs).unref();
    }

    function tooMany(c: Context, retryAfterMs: number) {
        const seconds = Math.max(1, Math.ceil(retryAfterMs / 1000));
        c.header("Retry-After", String(seconds));
        // One caller's 429 must never be served to others from a cache.
        c.header("Cache-Control", "no-store");
        return c.json({ error: `Rate limit exceeded. Try again in ${seconds}s.`, retryAfter: seconds }, 429);
    }

    /** The old sliding window, keyed on the real address, with an honest Retry-After. */
    function legacy(client: string): { ok: true; remaining: number } | { ok: false; retryAfterMs: number } {
        const at = now();
        let stamps = window.get(client);
        if (!stamps) {
            stamps = [];
            window.set(client, stamps);
        }
        const cutoff = at - options.legacyWindowMs;
        while (stamps.length > 0 && stamps[0] < cutoff) stamps.shift();
        if (stamps.length >= options.legacyMax) {
            return { ok: false, retryAfterMs: stamps[0] + options.legacyWindowMs - at };
        }
        stamps.push(at);
        return { ok: true, remaining: options.legacyMax - stamps.length };
    }

    const middleware: MiddlewareHandler = async (c, next) => {
        const header = (name: string) => c.req.header(name);
        const service = keyName(header("x-internal-secret"));
        const client = clientAddress(header);

        let decision: Decision | null = null;
        let bucketId = "";
        let row: PathCount | null = null;
        if (options.mode !== "legacy") {
            const tier: Tier = service ? "internal" : tierOf(header);
            bucketId = service ? `internal:${service}` : `${tier}:${client}`;
            const cost = costOf(c.req.path, (name) => c.req.query(name));
            decision = buckets.take(bucketId, TIERS[tier], cost);
            record(tier, service ?? client, decision, cost);
            row = pathRow(service ?? tier, c.req.path);
            row.requests += 1;
            row.tokens += cost;
            // Watching only: a "hold" took its tokens, so the queue it simulates stays real, but
            // nothing waits.
            if (options.mode === "shadow" && decision.action === "hold") buckets.release(bucketId);
        }

        if (options.mode === "enforce" && decision) {
            if (decision.action === "reject") return tooMany(c, decision.retryAfterMs);
            if (decision.action === "hold") {
                try {
                    await sleep(decision.waitMs);
                } finally {
                    buckets.release(bucketId);
                }
            }
            await next();
            if (row && c.res.status >= 400) row.errors += 1;
            const allowed = decision;
            editHeaders(c, (headers) => {
                if (isEdgeCacheable(headers.get("Cache-Control"))) {
                    for (const name of RATE_HEADERS) headers.delete(name);
                } else if (allowed.action === "allow") {
                    headers.set("RateLimit-Limit", String(allowed.limit));
                    headers.set("RateLimit-Remaining", String(allowed.remaining));
                    headers.set("RateLimit-Reset", String(allowed.resetSeconds));
                }
            });
            return;
        }

        // legacy and shadow: the sliding window decides. Internal keys skip it, as before.
        if (!service) {
            const verdict = legacy(client);
            if (!verdict.ok) {
                legacyRejected += 1;
                c.header("X-RateLimit-Limit", String(options.legacyMax));
                c.header("X-RateLimit-Remaining", "0");
                return tooMany(c, verdict.retryAfterMs);
            }
            c.header("X-RateLimit-Limit", String(options.legacyMax));
            c.header("X-RateLimit-Remaining", String(verdict.remaining));
        }
        await next();
        if (row && c.res.status >= 400) row.errors += 1;
        editHeaders(c, (headers) => {
            if (isEdgeCacheable(headers.get("Cache-Control"))) for (const name of RATE_HEADERS) headers.delete(name);
        });
    };

    return { middleware, keyName, snapshot };
}

export const limiter = createRateLimiter({
    mode: RATE_LIMIT_MODE,
    keys: INTERNAL_KEYS,
    legacyMax: RATE_LIMIT_MAX_REQUESTS,
    legacyWindowMs: RATE_LIMIT_WINDOW_MS,
    reportEveryMs: 5 * 60_000,
});

export const rateLimiter = limiter.middleware;

/**
 * GET /rate-limit/stats: this period's counters, for an internal key only. Anyone else gets the
 * same 404 as an unknown path.
 */
export const rateLimitStats: MiddlewareHandler = async (c) => {
    c.header("Cache-Control", "no-store");
    if (!limiter.keyName(c.req.header("x-internal-secret"))) return c.json({ error: "Not found" }, 404);
    return c.json(limiter.snapshot());
};

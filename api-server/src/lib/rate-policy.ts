/**
 * The rate-limit policy, as pure functions: who a caller is, which tier they are in, what a
 * request costs, and a token bucket per caller. No timers and no I/O, so tests drive it with a
 * fake clock. The middleware in ../middleware/rate-limit.ts applies it.
 *
 * Why tokens instead of a request count: a browser scrolling a grid bursts, then idles. A bucket
 * holds a burst and refills steadily, so the burst passes and only sustained load is limited.
 * Costs let one 200-image batch weigh more than one small JSON read.
 */

export type Tier = "internal" | "website" | "public" | "crawler";

export interface TierPolicy {
    /** Tokens a full bucket holds: the largest burst that passes untouched. */
    burst: number;
    /** Tokens refilled per second: the sustained rate. */
    perSecond: number;
}

/** Starting points, to be tuned from shadow-mode numbers before enforcing. */
export const TIERS: Record<Tier, TierPolicy> = {
    // Per service key. High enough for real work, low enough that a runaway loop shows.
    internal: { burst: 2_000, perSecond: 50 },
    // Browsers on normies.art and its subdomains. A soft signal (Origin/Referer can be copied),
    // so it is a bigger bucket per visitor, never an exemption.
    website: { burst: 400, perSecond: 5 },
    // Everyone else: today's 60 a minute sustained, plus room for a burst.
    public: { burst: 120, perSecond: 1 },
    // Bulk crawlers by user agent.
    crawler: { burst: 30, perSecond: 0.5 },
};

/** A request short by at most this much refill time waits instead of failing. */
export const HOLD_MAX_MS = 2_000;
/** At most this many requests per caller wait at once; the rest get a 429. */
export const MAX_HELD_PER_CLIENT = 4;

// ── Who is calling ────────────────────────────────────────────────────────────

/**
 * The caller's address. nginx sets X-Real-IP (and overwrites X-Forwarded-For) from Cloudflare's
 * CF-Connecting-IP, accepted only from Cloudflare's ranges, so both are trustworthy here. IPv6 is
 * grouped by its /64: one home or server gets a whole /64, and per-address buckets would hand a
 * single network thousands of budgets.
 */
export function clientAddress(get: (name: string) => string | undefined): string {
    const raw = (get("x-real-ip") ?? get("x-forwarded-for")?.split(",")[0] ?? "").trim();
    if (!raw) return "unknown";
    return raw.includes(":") ? ipv6Prefix64(raw) : raw;
}

export function ipv6Prefix64(address: string): string {
    const bare = address.replace(/^\[|\]$/g, "").split("%")[0].toLowerCase();
    // An IPv4-mapped address (::ffff:1.2.3.4) is really IPv4.
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(bare);
    if (mapped) return mapped[1];
    const [head, tail = ""] = bare.split("::");
    const left = head ? head.split(":") : [];
    const right = bare.includes("::") && tail ? tail.split(":") : [];
    const groups = bare.includes("::")
        ? [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right]
        : left;
    return `${groups.slice(0, 4).map((g) => (g || "0").replace(/^0+(?=.)/, "")).join(":")}::/64`;
}

// Link-preview bots fetch one page's image for many people from shared addresses; they stay public.
const PREVIEW_BOT = /twitterbot|discordbot|telegrambot|slackbot|slack-imgproxy|facebookexternalhit|whatsapp|linkedinbot|applebot|embedly/i;
const CRAWLER = /bot\b|bot\/|crawler|spider|slurp|gptbot|claudebot|ccbot|bytespider|petalbot|healthchecker/i;

function hostOf(value: string | undefined): string | null {
    if (!value) return null;
    try {
        return new URL(value).hostname.toLowerCase();
    } catch {
        return null;
    }
}

export function isFirstPartyHost(host: string | null): boolean {
    return host === "normies.art" || (host?.endsWith(".normies.art") ?? false);
}

/**
 * The tier of a caller that did not present an internal key. Every fetch from a page sends
 * `Origin`; an <img> sends `Referer`, which the site's default referrer policy includes.
 */
export function tierOf(get: (name: string) => string | undefined): Exclude<Tier, "internal"> {
    if (isFirstPartyHost(hostOf(get("origin"))) || isFirstPartyHost(hostOf(get("referer")))) return "website";
    const ua = get("user-agent") ?? "";
    if (!PREVIEW_BOT.test(ua) && CRAWLER.test(ua)) return "crawler";
    return "public";
}

// ── What a request costs ──────────────────────────────────────────────────────

/** Tokens a request takes, by what it costs the server. Most reads cost 1. */
export function costOf(path: string, query: (name: string) => string | undefined): number {
    if (path === "/normie/all/original/data") return 10;
    if (path === "/normie/images") {
        const ids = (query("ids") ?? "").split(",").filter(Boolean).length;
        return 1 + Math.ceil(Math.min(ids, 200) / 50);
    }
    if (path.startsWith("/agents/persona-preview/")) return 5;
    if (/^\/history\/normie\/\d+\/versions$/.test(path) && query("pixels") === "1") return 2;
    if (path.startsWith("/holders/") || path.startsWith("/rarity/holder/")) return 2;
    return 1;
}

// ── Token buckets ─────────────────────────────────────────────────────────────

export type Decision =
    | { action: "allow"; remaining: number; limit: number; resetSeconds: number }
    | { action: "hold"; waitMs: number; limit: number }
    | { action: "reject"; retryAfterMs: number; limit: number };

interface Bucket {
    tokens: number;
    at: number;
    held: number;
}

/**
 * One bucket per caller id. A held request takes its tokens up front, so the balance can go
 * negative: whoever comes next sees the queue ahead of them and waits, or is told how long.
 */
export class TokenBuckets {
    private buckets = new Map<string, Bucket>();

    constructor(private readonly now: () => number = Date.now) {}

    get size(): number {
        return this.buckets.size;
    }

    take(id: string, policy: TierPolicy, cost: number, { canHold = true } = {}): Decision {
        const now = this.now();
        const bucket = this.refill(id, policy, now);
        const limit = policy.burst;
        if (bucket.tokens >= cost) {
            bucket.tokens -= cost;
            return {
                action: "allow",
                remaining: Math.floor(bucket.tokens),
                limit,
                resetSeconds: Math.ceil((policy.burst - bucket.tokens) / policy.perSecond),
            };
        }
        const waitMs = Math.ceil(((cost - bucket.tokens) / policy.perSecond) * 1000);
        if (canHold && waitMs <= HOLD_MAX_MS && bucket.held < MAX_HELD_PER_CLIENT) {
            bucket.tokens -= cost;
            bucket.held += 1;
            return { action: "hold", waitMs, limit };
        }
        return { action: "reject", retryAfterMs: waitMs, limit };
    }

    /** A held request finished waiting. */
    release(id: string): void {
        const bucket = this.buckets.get(id);
        if (bucket && bucket.held > 0) bucket.held -= 1;
    }

    /** Drop buckets that have refilled completely: a new bucket starts full, so nothing is lost. */
    prune(policyOf: (id: string) => TierPolicy): void {
        const now = this.now();
        for (const id of [...this.buckets.keys()]) {
            const policy = policyOf(id);
            const bucket = this.refill(id, policy, now);
            if (bucket.held === 0 && bucket.tokens >= policy.burst) this.buckets.delete(id);
        }
    }

    private refill(id: string, policy: TierPolicy, now: number): Bucket {
        let bucket = this.buckets.get(id);
        if (!bucket) {
            bucket = { tokens: policy.burst, at: now, held: 0 };
            this.buckets.set(id, bucket);
            return bucket;
        }
        const elapsed = Math.max(0, now - bucket.at) / 1000;
        bucket.tokens = Math.min(policy.burst, bucket.tokens + elapsed * policy.perSecond);
        bucket.at = now;
        return bucket;
    }
}

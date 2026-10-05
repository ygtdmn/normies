import "dotenv/config";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { createPublicClient, decodeEventLog, http, toEventSelector, type AbiEvent, type Hex, type Log } from "viem";
import { mainnet } from "viem/chains";
import { ADMIN_SAFE, CONTRACTS, SAFES, WATCHED_EVENTS, nameOf, type Severity } from "./contracts.js";
import { ABI, describeCall, formatValue, safeCalls } from "./decode.js";

/**
 * Watches the Normies contracts and Safes on mainnet and posts every admin event and every Safe transaction to
 * Discord, grouped per transaction. Urgent ones (ownership, roles, writers, money routes, epochs, any Admin Safe
 * transaction, any Safe signer change) mention DISCORD_MENTION. It resumes from the last block it finished, so a
 * restart or a crash never skips a block.
 *
 * Env: RPC_URL, DISCORD_WEBHOOK_URL; optional DISCORD_MENTION, WATCHER_STATE (/var/lib/normies-watcher/state.json),
 * WATCH_FROM_BLOCK (first start only; default the current block), CONFIRMATIONS (3), POLL_SECONDS (30),
 * CHUNK_BLOCKS (500), ADMIN_SAFE, OPERATIONS_SAFE.
 */
const RPC_URL = process.env.RPC_URL;
const WEBHOOK = process.env.DISCORD_WEBHOOK_URL;
const MENTION = process.env.DISCORD_MENTION?.trim() ?? "";
const STATE = process.env.WATCHER_STATE ?? "/var/lib/normies-watcher/state.json";
const CONFIRMATIONS = BigInt(process.env.CONFIRMATIONS ?? 3);
const POLL_MS = Number(process.env.POLL_SECONDS ?? 30) * 1000;
const CHUNK = BigInt(process.env.CHUNK_BLOCKS ?? 500);
const DOWN_ALERT_MS = 10 * 60_000;

if (!RPC_URL) throw new Error("RPC_URL is not set");
const client = createPublicClient({ chain: mainnet, transport: http(RPC_URL, { timeout: 30_000, retryCount: 2 }) });

const events = (ABI as readonly AbiEvent[]).filter((e) => e.type === "event" && e.name in WATCHED_EVENTS);
const topics = [...new Set(events.map((e) => toEventSelector(e)))];
const eventByTopic = new Map(events.map((e) => [toEventSelector(e).toLowerCase(), e.name]));
const addresses = [...Object.keys(CONTRACTS), ...Object.keys(SAFES)] as Hex[];

// ──────────────────────────────────────────────
//  Discord
// ──────────────────────────────────────────────

async function discord(content: string): Promise<void> {
    if (!WEBHOOK) {
        console.log(`[discord disabled] ${content}`);
        return;
    }
    for (let i = 0; i < content.length; i += 1900) {
        const chunk = content.slice(i, i + 1900);
        for (let attempt = 0; attempt < 5; attempt++) {
            const res = await fetch(WEBHOOK, {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ content: chunk, allowed_mentions: { parse: ["users", "roles", "everyone"] } }),
            }).catch(() => null);
            if (res && res.status !== 429 && res.ok) break;
            const wait = res?.status === 429 ? Number((await res.json().catch(() => ({})) as { retry_after?: number }).retry_after ?? 2) : 5;
            await new Promise((r) => setTimeout(r, Math.ceil(wait * 1000)));
        }
    }
}

// ──────────────────────────────────────────────
//  State
// ──────────────────────────────────────────────

function loadState(): bigint | null {
    if (!existsSync(STATE)) return null;
    try {
        return BigInt((JSON.parse(readFileSync(STATE, "utf8")) as { lastBlock: string }).lastBlock);
    } catch {
        return null;
    }
}

function saveState(lastBlock: bigint): void {
    mkdirSync(dirname(STATE), { recursive: true });
    writeFileSync(STATE, `${JSON.stringify({ lastBlock: lastBlock.toString(), at: new Date().toISOString() })}\n`);
}

// ──────────────────────────────────────────────
//  One transaction, one message
// ──────────────────────────────────────────────

const RANK: Record<Severity, number> = { notice: 0, urgent: 1 };

async function describeTransaction(hash: Hex, logs: Log[]): Promise<{ severity: Severity; text: string }> {
    let severity: Severity = "notice";
    const lines: string[] = [];
    let safeExecuted: string | null = null;

    for (const log of logs) {
        let decoded: { eventName: unknown; args?: unknown } | null = null;
        try {
            decoded = decodeEventLog({ abi: ABI, data: log.data, topics: log.topics });
        } catch {
            // Watched by topic but laid out differently (another Safe version): still reported, undecoded.
        }
        const name = decoded ? String(decoded.eventName) : (eventByTopic.get(String(log.topics[0]).toLowerCase()) ?? "unknown event");
        let s = WATCHED_EVENTS[name] ?? "notice";
        const emitter = log.address.toLowerCase();
        if (name === "ExecutionSuccess" || name === "ExecutionFailure") {
            safeExecuted = emitter;
            if (emitter === ADMIN_SAFE || name === "ExecutionFailure") s = "urgent";
            lines.push(`${name === "ExecutionSuccess" ? "executed" : "FAILED"}: ${nameOf(emitter)} transaction`);
        } else {
            const args = decoded?.args && typeof decoded.args === "object" ? Object.entries(decoded.args as unknown as Record<string, unknown>) : [];
            lines.push(`${nameOf(emitter)}.${name}(${decoded ? args.map(([k, v]) => `${k}=${formatValue(v)}`).join(", ") : "undecoded"})`);
        }
        if (RANK[s] > RANK[severity]) severity = s;
        if (name === "EpochPosted") {
            lines.push(
                "If you did not just run `revshare.sh approve`, treat the poster key as stolen: the Operations Safe sends " +
                    "cancelEpoch(id) + pool.setPaused(true) in one batch NOW, then the Admin Safe revokes the poster role.",
            );
        }
    }

    // Name what a Safe did, call by call.
    if (safeExecuted) {
        const tx = await client.getTransaction({ hash }).catch(() => null);
        const calls = tx && tx.to?.toLowerCase() === safeExecuted ? safeCalls(tx.input) : null;
        if (calls) {
            for (const call of calls) lines.push(`  -> ${describeCall(call)}`);
            if (tx) lines.push(`  sent by signer ${tx.from}`);
        } else {
            lines.push("  (sent through another contract; open the transaction to see the calls)");
        }
    }

    const head = severity === "urgent" ? `${MENTION ? `${MENTION} ` : ""}**URGENT**` : "**Notice**";
    const block = logs[0]?.blockNumber != null ? BigInt(logs[0].blockNumber).toString() : "?";
    return {
        severity,
        text: `${head} Normies on-chain change in block ${block}\n${lines.join("\n")}\nhttps://etherscan.io/tx/${hash}`,
    };
}

async function scan(from: bigint, to: bigint): Promise<void> {
    const logs = (await client.request({
        method: "eth_getLogs",
        params: [{ address: addresses, topics: [topics], fromBlock: `0x${from.toString(16)}`, toBlock: `0x${to.toString(16)}` }],
    })) as unknown as Log[];
    const byTx = new Map<Hex, Log[]>();
    for (const log of logs) {
        const parsed = { ...log, blockNumber: BigInt(log.blockNumber as unknown as string) } as Log;
        const list = byTx.get(log.transactionHash!) ?? [];
        list.push(parsed);
        byTx.set(log.transactionHash!, list);
    }
    for (const [hash, txLogs] of byTx) {
        const { text } = await describeTransaction(hash, txLogs);
        console.log(text.replace(/\n/g, " | "));
        await discord(text);
    }
}

// ──────────────────────────────────────────────
//  Loop
// ──────────────────────────────────────────────

async function main() {
    const head = await client.getBlockNumber();
    let last = loadState() ?? (process.env.WATCH_FROM_BLOCK ? BigInt(process.env.WATCH_FROM_BLOCK) - 1n : head - CONFIRMATIONS);
    await discord(
        `Normies watcher started: ${Object.keys(CONTRACTS).length} contracts and ${Object.keys(SAFES).length} Safes, resuming after block ${last}.`,
    );
    let failingSince: number | null = null;
    let downAlerted = false;

    for (;;) {
        try {
            const target = (await client.getBlockNumber()) - CONFIRMATIONS;
            while (last < target) {
                const to = last + CHUNK < target ? last + CHUNK : target;
                await scan(last + 1n, to);
                last = to;
                saveState(last);
            }
            if (downAlerted) await discord(`Normies watcher recovered and caught up to block ${last}.`);
            failingSince = null;
            downAlerted = false;
        } catch (err) {
            console.error(err);
            failingSince ??= Date.now();
            if (!downAlerted && Date.now() - failingSince > DOWN_ALERT_MS) {
                downAlerted = true;
                await discord(
                    `${MENTION ? `${MENTION} ` : ""}**Normies watcher is blind**: it has failed for 10 minutes (stuck after block ${last}). ` +
                        `Last error: ${String((err as Error)?.message ?? err).slice(0, 300)}`,
                );
            }
        }
        await new Promise((r) => setTimeout(r, POLL_MS));
    }
}

/** `replay <from> <to>`: print what the watcher would have posted for a past range, without Discord or state. */
async function replay(from: bigint, to: bigint) {
    for (let start = from; start <= to; start += CHUNK) {
        const end = start + CHUNK - 1n < to ? start + CHUNK - 1n : to;
        const logs = (await client.request({
            method: "eth_getLogs",
            params: [{ address: addresses, topics: [topics], fromBlock: `0x${start.toString(16)}`, toBlock: `0x${end.toString(16)}` }],
        })) as unknown as Log[];
        const byTx = new Map<Hex, Log[]>();
        for (const log of logs) byTx.set(log.transactionHash!, [...(byTx.get(log.transactionHash!) ?? []), log]);
        for (const [hash, txLogs] of byTx) console.log(`${(await describeTransaction(hash, txLogs)).text}\n`);
    }
}

if (process.argv[2] === "replay") {
    replay(BigInt(process.argv[3]), BigInt(process.argv[4])).catch((err) => {
        console.error(err);
        process.exit(1);
    });
} else main().catch(async (err) => {
    console.error(err);
    await discord(`${MENTION ? `${MENTION} ` : ""}**Normies watcher crashed** and will restart: ${String(err?.message ?? err).slice(0, 300)}`).catch(() => {});
    process.exit(1);
});

/**
 * Backfills agentsPrisma.Agent rows from the on-chain truth captured by the
 * Ponder indexer. Users who register their Normie as an ERC-8004 agent but
 * close the lab page before `register-complete` runs leave the agentsPrisma
 * row pending — or, if they bypassed the lab UI entirely, missing — which
 * makes `/agents/info/:tokenId` 404 forever. This module promotes those rows
 * to `registered` using the AgentBound event the indexer already saw.
 *
 * Two entry points:
 *   - `reconcileTokenId(tokenId)` — lazy single-token reconcile, called from
 *     the read endpoints when they miss.
 *   - `reconcileAll()` — paginated sweep over all Normies bindings in Ponder,
 *     started on api-server boot and run on an interval. Idempotent.
 */
import { agentsPrisma } from "../lib/agents-db.js";
import { getDecodedTraits } from "./token-data.js";
import { getAgentBinding, getAllAgentBindings, type AgentBindingData } from "./ponder-data.js";
import { CHAIN_ID, NORMIES_ADDRESS, PONDER_ENABLED } from "../config.js";

// Whitelist of immutable mint-time traits. Mirrors the lab's register-prepare
// filter — anything outside this set is mutable on-chain state that must not
// be frozen into the agents DB.
const STATIC_TRAITS = new Set([
    "Type",
    "Gender",
    "Age",
    "Hair Style",
    "Facial Feature",
    "Expression",
    "Eyes",
    "Accessory",
]);

function staticAttributes(all: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    for (const k of Object.keys(all)) {
        if (STATIC_TRAITS.has(k)) out[k] = all[k];
    }
    return out;
}

function tokenIdName(tokenId: bigint): string {
    return `Normie #${tokenId.toString()}`;
}

/**
 * Promote (or insert) one Normie's agentsPrisma row to match an on-chain
 * binding. Idempotent — safe to call when the row is already registered.
 * Returns the resulting row, or null if no on-chain binding exists.
 */
export async function reconcileTokenId(tokenId: bigint) {
    const existing = await agentsPrisma.agent.findUnique({ where: { tokenId } });
    if (existing && existing.status === "registered" && existing.agentId !== null) {
        return existing; // already settled
    }

    if (!PONDER_ENABLED) return existing; // can't reach binding source — leave as-is

    let binding: AgentBindingData | null;
    try {
        binding = await getAgentBinding(NORMIES_ADDRESS, tokenId);
    } catch {
        return existing; // indexer transient failure — next sweep will retry
    }
    if (!binding) return existing; // not registered on-chain

    return promoteFromBinding(tokenId, binding, existing);
}

async function promoteFromBinding(
    tokenId: bigint,
    binding: AgentBindingData,
    existing: Awaited<ReturnType<typeof agentsPrisma.agent.findUnique>>,
) {
    const agentId = BigInt(binding.agentId);
    const registeredBy = binding.registeredBy;
    const txHash = binding.txHash;

    if (existing) {
        // Pending row from a started-but-abandoned register-prepare. Fill in
        // the on-chain facts and flip status — keep the lab-supplied traits
        // and createdBy intact.
        return agentsPrisma.agent.update({
            where: { tokenId },
            data: {
                agentId,
                txHash,
                status: "registered",
                registeredBy,
            },
        });
    }

    // No row at all: user bypassed the lab UI. Build the traits snapshot from
    // on-chain reads. Failures bubble up so the caller (sweep / read handler)
    // can log and retry later; we'd rather skip a row than persist garbage.
    //
    // Upsert (not create) because the sweep and the lazy read-path reconcile
    // can both observe the same missing row and race to insert it. Prisma
    // emits a single INSERT ... ON CONFLICT, so the loser takes the update
    // branch instead of throwing on Agent_tokenId_key.
    const attributes = await getDecodedTraits(Number(tokenId));
    return agentsPrisma.agent.upsert({
        where: { tokenId },
        update: {
            agentId,
            txHash,
            status: "registered",
            registeredBy,
        },
        create: {
            tokenId,
            agentId,
            chainId: CHAIN_ID,
            traits: { name: tokenIdName(tokenId), attributes: staticAttributes(attributes) },
            status: "registered",
            txHash,
            registeredBy,
            // No lab session attached, so the on-chain caller is the best
            // attribution we have for who created the registration.
            createdBy: registeredBy,
        },
    });
}

export interface ReconcileSummary {
    scanned: number;
    promoted: number;
    alreadyRegistered: number;
    errors: number;
}

/**
 * Paginated sweep over every Normies binding the indexer has seen. Pages
 * through `/agent-bindings` (newest first) until exhausted. Per-row failures
 * are counted but do not abort the sweep — the next interval will retry.
 */
export async function reconcileAll(opts: { pageSize?: number } = {}): Promise<ReconcileSummary> {
    const summary: ReconcileSummary = { scanned: 0, promoted: 0, alreadyRegistered: 0, errors: 0 };
    if (!PONDER_ENABLED) return summary;

    const pageSize = Math.min(Math.max(opts.pageSize ?? 100, 1), 100);
    let offset = 0;

    // Guard against runaway pagination if the indexer ever stops setting
    // hasMore correctly. 50 pages × 100 = 5000 bindings — well above the
    // expected Normies registration count for the foreseeable future.
    const MAX_PAGES = 50;

    for (let page = 0; page < MAX_PAGES; page++) {
        let res;
        try {
            res = await getAllAgentBindings({
                tokenContract: NORMIES_ADDRESS,
                limit: pageSize,
                offset,
            });
        } catch {
            summary.errors++;
            break; // indexer unreachable — bail; next sweep retries
        }

        for (const binding of res.bindings) {
            summary.scanned++;
            const tokenId = BigInt(binding.tokenId);
            try {
                const existing = await agentsPrisma.agent.findUnique({ where: { tokenId } });
                if (existing && existing.status === "registered" && existing.agentId !== null) {
                    summary.alreadyRegistered++;
                    continue;
                }
                await promoteFromBinding(tokenId, binding, existing);
                summary.promoted++;
            } catch {
                summary.errors++;
            }
        }

        if (!res.hasMore) break;
        offset += pageSize;
    }

    return summary;
}

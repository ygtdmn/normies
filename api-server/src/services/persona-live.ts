/**
 * Compose a full Persona from live on-chain + indexer state. Pure read helper,
 * no DB access — feeds the agentURI endpoints (info / metadata / agent-card)
 * and the lab's awakening-time persona-preview endpoint.
 *
 * Trait reads are cached for the lifetime of the process (traits are
 * immutable post-mint); canvas reads share the existing short-TTL canvas
 * caches; transformation history comes from Ponder when available, falling
 * back to a single-entry estimate if the indexer is unreachable.
 */

import {
    generatePersona,
    type Persona,
    type PersonaCanvasDiff,
    type PersonaVersion,
} from "../lib/persona.js";
import { computePixelDiff } from "../lib/diff.js";
import { getDecodedTraits, getImageData } from "./token-data.js";
import { getCanvasInfo, getTransformData } from "./canvas-data.js";
import { getTransformHistory } from "./ponder-data.js";
import { PONDER_ENABLED } from "../config.js";

export async function buildLivePersona(tokenId: number): Promise<Persona> {
    const [attributes, canvas] = await Promise.all([
        getDecodedTraits(tokenId),
        getCanvasInfo(tokenId),
    ]);

    let diff: PersonaCanvasDiff | null = null;
    if (canvas.customized) {
        try {
            const [original, transform] = await Promise.all([
                getImageData(tokenId),
                getTransformData(tokenId),
            ]);
            diff = computePixelDiff(original, transform);
        } catch {
            // Pixel diff is an optional enrichment; persona generation
            // doesn't require it. Leave null on read failure.
        }
    }

    let versions: PersonaVersion[] = [];
    if (PONDER_ENABLED) {
        try {
            const history = await getTransformHistory(tokenId);
            versions = history.map((t) => ({
                version: t.version ?? 0,
                changeCount: t.changeCount,
                newPixelCount: t.newPixelCount,
                transformer: t.transformer,
                blockNumber: t.blockNumber,
                timestamp: t.timestamp,
                txHash: t.txHash,
            }));
        } catch {
            // Indexer unreachable — falls back to customized ? 1 : 0 below.
        }
    }

    const transformationCount = versions.length || (canvas.customized ? 1 : 0);

    return generatePersona(
        BigInt(tokenId),
        { attributes },
        {
            customized: canvas.customized,
            level: canvas.level,
            actionPoints: canvas.actionPoints,
            transformationCount,
            delegate: canvas.delegate,
        },
        diff,
        versions,
    );
}

/**
 * Lightweight identity-only persona — just name + type derived from immutable
 * traits, no canvas reads. Used by gallery / picker lookups where the full
 * persona is overkill. Returns the same name/type that `buildLivePersona`
 * would yield (both call into `generatePersona` with identical seeding).
 */
export async function buildAgentIdentity(
    tokenId: number,
): Promise<{ tokenId: number; name: string; type: string; traits: Record<string, string> }> {
    const attributes = await getDecodedTraits(tokenId);
    // Run the full generator with an untouched canvas — name + type are
    // band-independent so the choice doesn't matter.
    const persona = generatePersona(
        BigInt(tokenId),
        { attributes },
        { customized: false, level: 1, actionPoints: 0, transformationCount: 0 },
        null,
        [],
    );
    return {
        tokenId,
        name: persona.name,
        type: persona.type,
        traits: attributes,
    };
}

export { type Persona } from "../lib/persona.js";

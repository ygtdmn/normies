import type { Context } from "ponder:registry";
import { canvasTokenState } from "ponder:schema";

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export type IndexingContext = Context;
export type EventMeta = {
  blockNumber: bigint;
  timestamp: bigint;
  txHash: `0x${string}`;
};

export function eventMeta(event: {
  block: { number: bigint; timestamp: bigint };
  transaction: { hash: `0x${string}` };
}): EventMeta {
  return {
    blockNumber: event.block.number,
    timestamp: event.block.timestamp,
    txHash: event.transaction.hash,
  };
}

// ──────────────────────────────────────────────
//  Bitmaps (mirror NormiesBitmap.sol)
// ──────────────────────────────────────────────

export function bytesForGrid(n: number): number {
  return (n * n + 7) >> 3;
}

/** Grid side for a bitmap of `len` bytes; the five supported sizes are exact, anything else is a best guess. */
export function gridSizeFromLength(len: number): number {
  switch (len) {
    case 200: return 40;
    case 313: return 50;
    case 450: return 60;
    case 613: return 70;
    case 800: return 80;
    default: return Math.max(1, Math.round(Math.sqrt(len * 8)));
  }
}

export function popcountBytes(bytes: Uint8Array): number {
  let count = 0;
  for (let i = 0; i < bytes.length; i++) {
    let b = bytes[i]!;
    while (b) {
      b &= b - 1;
      count++;
    }
  }
  return count;
}

/** "On" pixels of an n x n bitmap, ignoring the padding bits of the final byte. */
export function countPixels(bytes: Uint8Array, n: number): number {
  let count = popcountBytes(bytes);
  const pad = (8 - ((n * n) & 7)) & 7;
  if (pad !== 0 && bytes.length > 0) {
    let tail = bytes[bytes.length - 1]! & ((1 << pad) - 1);
    while (tail) {
      tail &= tail - 1;
      count--;
    }
  }
  return count;
}

export function compositeBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const len = Math.max(a.length, b.length);
  const out = new Uint8Array(len);
  for (let i = 0; i < len; i++) out[i] = (a[i] ?? 0) ^ (b[i] ?? 0);
  return out;
}

/** Copies a fromN x fromN bitmap into the centre of a toN x toN bitmap. */
export function embedCentered(src: Uint8Array, fromN: number, toN: number): Uint8Array {
  if (fromN === toN) return Uint8Array.from(src);
  const out = new Uint8Array(bytesForGrid(toN));
  const off = (toN - fromN) >> 1;
  const total = fromN * fromN;
  for (let i = 0; i < src.length; i++) {
    const b = src[i]!;
    if (b === 0) continue;
    for (let bit = 0; bit < 8; bit++) {
      if (((b >> (7 - bit)) & 1) === 0) continue;
      const flat = i * 8 + bit;
      if (flat >= total) break;
      const o = (Math.floor(flat / fromN) + off) * toN + (flat % fromN) + off;
      out[o >> 3] = out[o >> 3]! | (0x80 >> (o & 7));
    }
  }
  return out;
}

// ──────────────────────────────────────────────
//  canvas_token_state upserts
// ──────────────────────────────────────────────

export async function upsertDefaultCanvasState(
  context: IndexingContext,
  tokenId: bigint,
  meta: EventMeta,
): Promise<void> {
  await context.db
    .insert(canvasTokenState)
    .values({
      tokenId,
      actionPoints: 0n,
      customized: false,
      delegate: ZERO_ADDRESS,
      delegateSetBy: ZERO_ADDRESS,
      latestTransformBitmap: null,
      gridSize: 40,
      baseCleared: false,
      migrated: false,
      lockedPixels: 0,
      blockNumber: meta.blockNumber,
      timestamp: meta.timestamp,
      txHash: meta.txHash,
    })
    .onConflictDoNothing();
}

export type CanvasStatePatch = {
  actionPoints?: bigint;
  customized?: boolean;
  delegate?: `0x${string}`;
  delegateSetBy?: `0x${string}`;
  latestTransformBitmap?: `0x${string}` | null;
  gridSize?: number;
  baseCleared?: boolean;
  migrated?: boolean;
  lockedPixels?: number;
};

export async function upsertCanvasState(
  context: IndexingContext,
  tokenId: bigint,
  values: CanvasStatePatch,
  meta: EventMeta,
): Promise<void> {
  const existing = await context.db.find(canvasTokenState, { tokenId });
  const next = {
    tokenId,
    actionPoints: values.actionPoints ?? existing?.actionPoints ?? 0n,
    customized: values.customized ?? existing?.customized ?? false,
    delegate: values.delegate ?? existing?.delegate ?? ZERO_ADDRESS,
    delegateSetBy: values.delegateSetBy ?? existing?.delegateSetBy ?? ZERO_ADDRESS,
    latestTransformBitmap: values.latestTransformBitmap !== undefined
      ? values.latestTransformBitmap
      : existing?.latestTransformBitmap ?? null,
    gridSize: values.gridSize ?? existing?.gridSize ?? 40,
    baseCleared: values.baseCleared ?? existing?.baseCleared ?? false,
    migrated: values.migrated ?? existing?.migrated ?? false,
    lockedPixels: values.lockedPixels ?? existing?.lockedPixels ?? 0,
    blockNumber: meta.blockNumber,
    timestamp: meta.timestamp,
    txHash: meta.txHash,
  };

  await context.db
    .insert(canvasTokenState)
    .values(next)
    .onConflictDoUpdate({
      actionPoints: next.actionPoints,
      customized: next.customized,
      delegate: next.delegate,
      delegateSetBy: next.delegateSetBy,
      latestTransformBitmap: next.latestTransformBitmap,
      gridSize: next.gridSize,
      baseCleared: next.baseCleared,
      migrated: next.migrated,
      lockedPixels: next.lockedPixels,
      blockNumber: next.blockNumber,
      timestamp: next.timestamp,
      txHash: next.txHash,
    });
}

/**
 * Query-string parsing that never turns into a 500. A whole-number parameter that is missing, empty,
 * non-numeric or not finite falls back to its default; anything else is floored and clamped. Lookups keyed by a
 * query value only hit the table's own keys, never Object.prototype members like "constructor" or "__proto__".
 */
export function queryInt(raw: string | undefined, fallback: number, min: number, max = Number.MAX_SAFE_INTEGER): number {
  const n = raw === undefined || raw.trim() === "" ? Number.NaN : Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(Math.max(Math.floor(n), min), max);
}

export function ownKey<T extends object>(table: T, key: string | undefined): key is Extract<keyof T, string> {
  return key !== undefined && Object.hasOwn(table, key);
}

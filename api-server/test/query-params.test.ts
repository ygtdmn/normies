import { describe, expect, it } from "vitest";
import { queryInt } from "../src/lib/validation.js";
import { ownKey, queryInt as indexerQueryInt } from "../indexer/src/api/query.js";

// Audit D-I1: malformed query values must never reach the database or an object lookup as NaN or a prototype key.
describe.each([
    ["api", queryInt],
    ["indexer", indexerQueryInt],
])("queryInt (%s)", (_name, parse) => {
    it("falls back on missing, empty, non-numeric and non-finite values", () => {
        for (const raw of [undefined, "", "  ", "abc", "NaN", "Infinity", "-Infinity", "1e400", "constructor"]) {
            expect(parse(raw, 50, 1, 100)).toBe(50);
        }
    });

    it("floors and clamps real numbers", () => {
        expect(parse("7", 50, 1, 100)).toBe(7);
        expect(parse("7.9", 50, 1, 100)).toBe(7);
        expect(parse("0", 50, 1, 100)).toBe(1);
        expect(parse("-5", 0, 0)).toBe(0);
        expect(parse("100000", 50, 1, 100)).toBe(100);
        expect(parse("0x10", 50, 1, 100)).toBe(16);
    });
});

describe("ownKey", () => {
    const table = { "price-asc": 1, newest: 2 };

    it("accepts only the table's own keys", () => {
        expect(ownKey(table, "price-asc")).toBe(true);
        expect(ownKey(table, "newest")).toBe(true);
    });

    it("rejects prototype members and missing keys", () => {
        for (const key of ["constructor", "__proto__", "toString", "hasOwnProperty", "nope", undefined]) {
            expect(ownKey(table, key)).toBe(false);
        }
    });
});

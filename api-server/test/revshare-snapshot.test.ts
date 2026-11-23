import type { PublicClient } from "viem";
import { describe, expect, it } from "vitest";
import { REVSHARE_CONFIG, type RevshareConfig } from "../src/revshare/config.js";
import { readState, type SnapshotAddresses } from "../src/revshare/snapshot.js";

const addresses: SnapshotAddresses = {
    normies: "0x00000000000000000000000000000000000000a0",
    pixelStorage: "0x00000000000000000000000000000000000000b0",
    market: "0x00000000000000000000000000000000000000c0",
};
const ARENA = REVSHARE_CONFIG.arenaStorage as `0x${string}`;
const ALICE = "0x00000000000000000000000000000000000000a1";
const BOB = "0x00000000000000000000000000000000000000b1";

/**
 * A chain with three Normies: #0 and #1 held by Alice, #2 by Bob, #3 burned. Arena balances by id: #1 = 40,
 * #2 = 7, #3 = 99 (a burned Normie's balance waits for rescue). Alice also has 10 pixels on #0 and 5 in her wallet.
 */
function fakeClient(options: { arenaDeployed: boolean }) {
    const calls: string[] = [];
    const owners: Record<number, string> = { 0: ALICE, 1: ALICE, 2: BOB };
    const arena: Record<number, bigint> = { 1: 40n, 2: 7n, 3: 99n };
    const client = {
        async multicall({ contracts }: { contracts: { address: string; functionName: string; args: [bigint | string] }[] }) {
            return contracts.map((c) => {
                calls.push(c.functionName);
                const arg = c.args[0];
                switch (c.functionName) {
                    case "ownerOf": {
                        const owner = owners[Number(arg)];
                        return owner ? { status: "success", result: owner } : { status: "failure" };
                    }
                    case "attachedOf":
                        return Number(arg) === 0 ? 10n : 0n;
                    case "balanceOf":
                        if (c.address === ARENA) return arena[Number(arg)] ?? 0n;
                        return arg === ALICE ? 5n : 0n;
                    default:
                        throw new Error(`unexpected ${c.functionName}`);
                }
            });
        },
        async getCode({ address }: { address: string }) {
            calls.push(`getCode:${address}`);
            return options.arenaDeployed ? "0x6080" : undefined;
        },
        async readContract() {
            return 1n; // nextListingId: no listings
        },
    };
    return { client: client as unknown as PublicClient, calls };
}

const pixelsOf = (states: { address: string; pixels: bigint }[]) => Object.fromEntries(states.map((s) => [s.address, s.pixels]));

describe("readState and the Arena", () => {
    it("credits each live Normie's Arena balance to its holder (version 5)", async () => {
        const { client } = fakeClient({ arenaDeployed: true });
        const states = await readState(client, addresses, 100n, REVSHARE_CONFIG);
        expect(pixelsOf(states)).toEqual({ [ALICE]: 10n + 5n + 40n, [BOB]: 7n });
        expect(states.find((s) => s.address === ALICE)?.tokens).toBe(2);
    });

    it("reads nothing from the Arena before its storage was deployed", async () => {
        const { client, calls } = fakeClient({ arenaDeployed: false });
        const states = await readState(client, addresses, 100n, REVSHARE_CONFIG);
        expect(pixelsOf(states)).toEqual({ [ALICE]: 15n, [BOB]: 0n });
        expect(calls.filter((c) => c === "balanceOf")).toHaveLength(2); // the two holders' wallet balances only
    });

    it("leaves older configs exactly as they were, so posted epochs rebuild the same", async () => {
        const { client, calls } = fakeClient({ arenaDeployed: true });
        const v4: RevshareConfig = { ...REVSHARE_CONFIG, version: 4 };
        delete v4.arenaStorage;
        const states = await readState(client, addresses, 100n, v4);
        expect(pixelsOf(states)).toEqual({ [ALICE]: 15n, [BOB]: 0n });
        expect(calls.some((c) => c.startsWith("getCode"))).toBe(false);
    });
});

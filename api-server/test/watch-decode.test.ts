import { describe, expect, it } from "vitest";
import { encodeFunctionData, encodePacked, parseAbi, type Hex } from "viem";
import { decodeMultiSend, describeCall, safeCalls } from "../src/watch/decode.js";

const pool = "0x481384812e79bf0d11FC0b1704af445D5F06813c";
const poolAbi = parseAbi(["function cancelEpoch(uint256)", "function setPaused(bool)"]);
const safeAbi = parseAbi([
    "function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures)",
    "function multiSend(bytes transactions)",
]);
const ZERO = "0x0000000000000000000000000000000000000000";
const exec = (to: Hex, data: Hex, operation: number) =>
    encodeFunctionData({ abi: safeAbi, functionName: "execTransaction", args: [to, 0n, data, operation, 0n, 0n, 0n, ZERO, ZERO, "0x"] });
const packed = (calls: { to: Hex; data: Hex }[]) =>
    `0x${calls.map((c) => encodePacked(["uint8", "address", "uint256", "uint256", "bytes"], [0, c.to, 0n, BigInt((c.data.length - 2) / 2), c.data]).slice(2)).join("")}` as Hex;

describe("watcher decoding", () => {
    const cancel = encodeFunctionData({ abi: poolAbi, functionName: "cancelEpoch", args: [3n] });
    const pause = encodeFunctionData({ abi: poolAbi, functionName: "setPaused", args: [true] });

    it("names a single Safe call", () => {
        const calls = safeCalls(exec(pool, pause, 0))!;
        expect(calls).toHaveLength(1);
        expect(describeCall(calls[0])).toBe("NormiesRevenuePool.setPaused(true)");
    });

    it("unpacks a MultiSend batch call by call", () => {
        const batch = encodeFunctionData({ abi: safeAbi, functionName: "multiSend", args: [packed([{ to: pool, data: cancel }, { to: pool, data: pause }])] });
        const calls = safeCalls(exec("0x9641d764fc13c8B624c04430C7356C1C7C8102e2", batch, 1))!;
        expect(calls.map(describeCall)).toEqual(["NormiesRevenuePool.cancelEpoch(3)", "NormiesRevenuePool.setPaused(true)"]);
        expect(decodeMultiSend(packed([{ to: pool, data: "0x" }]))[0]).toMatchObject({ to: pool.toLowerCase(), data: "0x" });
    });

    it("is not fooled by something that is not an execTransaction", () => {
        expect(safeCalls(pause)).toBeNull();
    });
});

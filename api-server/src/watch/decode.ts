import { readFileSync } from "node:fs";
import { decodeFunctionData, type Abi, type Hex } from "viem";
import { nameOf } from "./contracts.js";

/** Write functions and events of every Normies contract plus the Safe's, generated from the compiled contracts. */
export const ABI = JSON.parse(readFileSync(new URL("./abi.json", import.meta.url), "utf8")) as Abi;

export interface Call {
    to: string;
    value: bigint;
    data: Hex;
    operation: number;
}

/** MultiSend's packed batch: operation (1 byte), to (20), value (32), data length (32), data. */
export function decodeMultiSend(packed: Hex): Call[] {
    const bytes = packed.slice(2);
    const calls: Call[] = [];
    let i = 0;
    while (i < bytes.length) {
        const operation = parseInt(bytes.slice(i, i + 2), 16);
        const to = `0x${bytes.slice(i + 2, i + 42)}`;
        const value = BigInt(`0x${bytes.slice(i + 42, i + 106)}`);
        const length = Number(BigInt(`0x${bytes.slice(i + 106, i + 170)}`));
        const data = `0x${bytes.slice(i + 170, i + 170 + length * 2)}` as Hex;
        calls.push({ operation, to, value, data });
        i += 170 + length * 2;
    }
    return calls;
}

/** A Safe execTransaction's calls, with a MultiSend batch unpacked. Null when `input` is not an execTransaction. */
export function safeCalls(input: Hex): Call[] | null {
    try {
        const { functionName, args } = decodeFunctionData({ abi: ABI, data: input });
        if (functionName !== "execTransaction" || !args) return null;
        const [to, value, data, operation] = args as [string, bigint, Hex, number];
        const inner = { to, value, data, operation: Number(operation) };
        try {
            const decoded = decodeFunctionData({ abi: ABI, data });
            if (decoded.functionName === "multiSend") return decodeMultiSend(decoded.args![0] as Hex);
        } catch {
            // not a batch
        }
        return [inner];
    } catch {
        return null;
    }
}

export function formatValue(v: unknown): string {
    if (typeof v === "bigint") return v.toString();
    if (Array.isArray(v)) return `[${v.map(formatValue).join(", ")}]`;
    if (typeof v === "string") return v.length > 70 ? `${v.slice(0, 34)}…${v.slice(-8)}` : nameOrAddress(v);
    if (v && typeof v === "object") return JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x));
    return String(v);
}

const nameOrAddress = (v: string) => (/^0x[0-9a-fA-F]{40}$/.test(v) && nameOf(v) !== v ? `${nameOf(v)} (${v})` : v);

const ETH = (wei: bigint) => `${(Number(wei / 10n ** 12n) / 1e6).toString()} ETH`;

/** One line per call: target, function and arguments, as far as the ABI can name them. */
export function describeCall(call: Call): string {
    const target = nameOf(call.to);
    const value = call.value > 0n ? ` sending ${ETH(call.value)}` : "";
    const via = call.operation === 1 ? " (delegatecall)" : "";
    if (call.data === "0x") return `${target}: plain transfer${value}${via}`;
    try {
        const { functionName, args } = decodeFunctionData({ abi: ABI, data: call.data });
        return `${target}.${functionName}(${(args ?? []).map(formatValue).join(", ")})${value}${via}`;
    } catch {
        return `${target}: unknown function ${call.data.slice(0, 10)}${value}${via}`;
    }
}

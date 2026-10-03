import { encodeFunctionData, parseAbi } from "viem";
import type { EpochFile } from "./build.js";

export const postEpochAbi = parseAbi([
    "function postEpoch(bytes32 root, uint256 amount, uint64 fromBlock, uint64 toBlock, bytes32 configHash, string dataURI) returns (uint256)",
]);

/**
 * A Safe Transaction Builder batch holding exactly one call: postEpoch for `epoch`, to `pool`. The Treasury Safe
 * imports it; nothing in it can move ETH (value 0) or call anything but the pool. The amount posted is the leaves'
 * total, which is what the pool reserves.
 */
export function safeBatch(epoch: EpochFile, pool: `0x${string}`, safe: `0x${string}`, dataURI: string, chainId: number) {
    const data = encodeFunctionData({
        abi: postEpochAbi,
        functionName: "postEpoch",
        args: [epoch.root, BigInt(epoch.total), BigInt(epoch.fromBlock), BigInt(epoch.toBlock), epoch.configHash, dataURI],
    });
    return {
        version: "1.0",
        chainId: String(chainId),
        createdAt: Date.now(),
        meta: {
            name: `Normies revenue share epoch ${epoch.epochId}`,
            description:
                `postEpoch(${epoch.root}, ${epoch.total} wei, blocks ${epoch.fromBlock}..${epoch.toBlock}). ` +
                `Before signing, every signer downloads ${dataURI} and runs ` +
                `RPC_URL=<your own archive RPC> pnpm revshare verify <that file>; it must print "verified" and "postable".`,
            txBuilderVersion: "1.16.5",
            createdFromSafeAddress: safe,
            createdFromOwnerAddress: "",
        },
        transactions: [{ to: pool, value: "0", data, contractMethod: null, contractInputsValues: null }],
    };
}

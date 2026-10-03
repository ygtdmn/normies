import { decodeFunctionData } from "viem";
import { describe, expect, it } from "vitest";
import type { EpochFile } from "../src/revshare/build.js";
import { REVSHARE_CONFIG, configHash } from "../src/revshare/config.js";
import { postEpochAbi, safeBatch } from "../src/revshare/proposal.js";

const POOL = "0x00000000000000000000000000000000000000f1";
const SAFE = "0x00000000000000000000000000000000000000f2";

const epoch: EpochFile = {
    epochId: "7",
    fromBlock: "26000001",
    toBlock: "26200000",
    amount: "5000000000000000000",
    total: "4999999999999999990",
    root: "0xabababababababababababababababababababababababababababababababab",
    configHash: configHash(REVSHARE_CONFIG),
    config: REVSHARE_CONFIG,
    chainId: 1,
    addresses: {},
    excluded: [],
    sampleBlocks: [],
    leaves: [],
};

describe("safeBatch", () => {
    const batch = safeBatch(epoch, POOL, SAFE, "https://api.normies.art/revshare/epochs/7", 1);

    it("holds exactly one zero-value call to the pool", () => {
        expect(batch.chainId).toBe("1");
        expect(batch.meta.createdFromSafeAddress).toBe(SAFE);
        expect(batch.transactions).toHaveLength(1);
        expect(batch.transactions[0].to).toBe(POOL);
        expect(batch.transactions[0].value).toBe("0");
    });

    it("decodes back to the epoch: root, the leaves' total (not the amount), range, config and dataURI", () => {
        const { functionName, args } = decodeFunctionData({ abi: postEpochAbi, data: batch.transactions[0].data });
        expect(functionName).toBe("postEpoch");
        expect(args).toEqual([
            epoch.root,
            4999999999999999990n,
            26000001n,
            26200000n,
            epoch.configHash,
            "https://api.normies.art/revshare/epochs/7",
        ]);
    });

    it("tells signers to verify on their own RPC before signing", () => {
        expect(batch.meta.description).toMatch(/pnpm revshare verify/);
        expect(batch.meta.description).toMatch(/own archive RPC/);
    });
});

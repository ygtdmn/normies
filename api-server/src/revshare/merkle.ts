import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import type { Payout } from "./epoch.js";

export interface EpochLeaf {
    index: number;
    account: `0x${string}`;
    amount: string;
    proof: `0x${string}`[];
}

const LEAF_ENCODING = ["uint256", "uint256", "address", "uint256"];

/**
 * Leaves are (epochId, index, account, amount), double hashed and pair-sorted: OpenZeppelin's StandardMerkleTree,
 * which is what NormiesRevenuePool.claim verifies. The index is the payout's position in address order and is what
 * the pool's claimed bitmap is keyed on.
 */
export function buildTree(epochId: bigint, payouts: Payout[]): { root: `0x${string}`; leaves: EpochLeaf[] } {
    if (payouts.length === 0) throw new Error("An epoch needs at least one payout");
    const values = payouts.map((p, index) => [epochId.toString(), index.toString(), p.account, p.amount.toString()]);
    const tree = StandardMerkleTree.of(values, LEAF_ENCODING);
    const leaves: EpochLeaf[] = [];
    for (const [i, value] of tree.entries()) {
        leaves.push({
            index: Number(value[1]),
            account: value[2] as `0x${string}`,
            amount: value[3],
            proof: tree.getProof(i) as `0x${string}`[],
        });
    }
    leaves.sort((a, b) => a.index - b.index);
    return { root: tree.root as `0x${string}`, leaves };
}

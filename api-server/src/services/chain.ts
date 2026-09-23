import { type PublicClient, createPublicClient, fallback, http } from "viem";
import { foundry, mainnet, sepolia } from "viem/chains";
import { CHAIN_ID, RPC_URLS } from "../config.js";

const transports = RPC_URLS.map((url) => http(url, { timeout: 30_000 }));

if (transports.length === 0) {
    throw new Error("At least one RPC_URL must be configured");
}

// A local Anvil mainnet fork carries mainnet's Multicall3, but viem's foundry
// chain definition does not list it, so multicall() would refuse to run.
const anvilFork = {
    ...foundry,
    contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" as const } },
};

export const publicClient: PublicClient = createPublicClient({
    chain: CHAIN_ID === 1 ? mainnet : CHAIN_ID === 31_337 ? anvilFork : sepolia,
    transport: transports.length > 1 ? fallback(transports) : transports[0],
});

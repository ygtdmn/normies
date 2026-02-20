import { type PublicClient, createPublicClient, fallback, http } from "viem";
import { mainnet } from "viem/chains";
import { RPC_URLS } from "../config.js";

const transports = RPC_URLS.map((url) => http(url, { timeout: 30_000 }));

if (transports.length === 0) {
    throw new Error("At least one RPC_URL must be configured");
}

export const publicClient: PublicClient = createPublicClient({
    chain: mainnet,
    transport: transports.length > 1 ? fallback(transports) : transports[0],
});

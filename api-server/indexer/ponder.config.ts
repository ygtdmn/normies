import { createConfig } from "ponder";
import { http, parseAbiItem } from "viem";

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} must be configured`);
  return value;
}

const chainId = Number(requiredEnv("PONDER_CHAIN_ID"));
const chainName = chainId === 1 ? "mainnet" : "sepolia";
const startBlock = Number(requiredEnv("PONDER_START_BLOCK"));

function addressList(name: string): readonly `0x${string}`[] {
  const addresses = requiredEnv(name)
    .split(",")
    .map((address) => address.trim())
    .filter(Boolean) as readonly `0x${string}`[];
  if (addresses.length === 0) throw new Error(`${name} must include at least one address`);
  return addresses;
}

const TransferEvent = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
);
const MintEvent = parseAbiItem(
  "event Mint(address indexed minter, uint256 indexed tokenId, bytes imageData, bytes8 traits)",
);
const DelegateSetEvent = parseAbiItem(
  "event DelegateSet(uint256 indexed tokenId, address indexed delegate)",
);
const DelegateRevokedEvent = parseAbiItem(
  "event DelegateRevoked(uint256 indexed tokenId, address indexed previousDelegate)",
);
const BurnCommittedEvent = parseAbiItem(
  "event BurnCommitted(uint256 indexed commitId, address indexed owner, uint256 indexed receiverTokenId, uint256 tokenCount, uint256 transferredActionPoints)",
);
const BurnRevealedEvent = parseAbiItem(
  "event BurnRevealed(uint256 indexed commitId, address indexed owner, uint256 indexed receiverTokenId, uint256 totalActions, bool expired)",
);
const PixelsTransformedEvent = parseAbiItem(
  "event PixelsTransformed(address indexed transformer, uint256 indexed tokenId, uint256 changeCount, uint256 newPixelCount)",
);
const AgentBoundEvent = parseAbiItem(
  "event AgentBound(uint256 indexed agentId, uint8 indexed standard, address indexed tokenContract, uint256 tokenId, address registeredBy)",
);

export default createConfig({
  chains: {
    [chainName]: {
      id: chainId,
      rpc: http(requiredEnv("PONDER_RPC_URL")),
    },
  },
  contracts: {
    Normies: {
      abi: [TransferEvent],
      chain: chainName,
      address: requiredEnv("PONDER_NORMIES_ADDRESS") as `0x${string}`,
      startBlock,
    },
    NormiesMinter: {
      abi: [MintEvent],
      chain: chainName,
      address: addressList("PONDER_MINTER_ADDRESSES"),
      startBlock: Number(process.env.PONDER_MINTER_START_BLOCK ?? startBlock),
    },
    NormiesCanvas: {
      abi: [
        DelegateSetEvent,
        DelegateRevokedEvent,
        BurnCommittedEvent,
        BurnRevealedEvent,
        PixelsTransformedEvent,
      ],
      chain: chainName,
      address: requiredEnv("PONDER_CANVAS_ADDRESS") as `0x${string}`,
      startBlock,
    },
    Adapter8004: {
      abi: [AgentBoundEvent],
      chain: chainName,
      address: requiredEnv("PONDER_ADAPTER_ADDRESS") as `0x${string}`,
      startBlock: Number(
        process.env.PONDER_ADAPTER_START_BLOCK ?? startBlock,
      ),
    },
  },
});

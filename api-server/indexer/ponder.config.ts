import { createConfig } from "ponder";
import { http, parseAbiItem } from "viem";

const chainId = Number(process.env.PONDER_CHAIN_ID);
const chainName = chainId === 1 ? "mainnet" : "sepolia";

const TransferEvent = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
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

export default createConfig({
  chains: {
    [chainName]: {
      id: chainId,
      rpc: http(process.env.PONDER_RPC_URL),
    },
  },
  contracts: {
    Normies: {
      abi: [TransferEvent],
      chain: chainName,
      address: process.env.PONDER_NORMIES_ADDRESS as `0x${string}`,
      startBlock: Number(process.env.PONDER_START_BLOCK),
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
      address: process.env.PONDER_CANVAS_ADDRESS as `0x${string}`,
      startBlock: Number(process.env.PONDER_START_BLOCK),
    },
  },
});

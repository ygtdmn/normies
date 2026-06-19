import { createConfig } from "ponder";
import { http, parseAbiItem } from "viem";

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} must be configured`);
  return value;
}

const chainId = Number(requiredEnv("PONDER_CHAIN_ID"));
const chainName =
  chainId === 1 ? "mainnet" : chainId === 11_155_111 ? "sepolia" : "anvil";
const startBlock = Number(requiredEnv("PONDER_START_BLOCK"));

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
const ZombieAddedEvent = parseAbiItem(
  "event ZombieAdded(uint256 indexed poolIndex, address bitmapPointer, address attributesPointer)",
);
const PoolSealedEvent = parseAbiItem("event PoolSealed(uint256 poolSize)");
const ZombieSetEvent = parseAbiItem(
  "event ZombieSet(uint256 indexed tokenId, uint256 indexed poolIndex)",
);
const MerkleRootSetEvent = parseAbiItem("event MerkleRootSet(bytes32 merkleRoot)");
const SeedBlockSetEvent = parseAbiItem("event SeedBlockSet(uint256 seedBlock)");
const SeedLockedEvent = parseAbiItem(
  "event SeedLocked(bytes32 seed, uint256 poolSize)",
);
const PausedSetEvent = parseAbiItem("event PausedSet(bool paused)");
const ZombieConvertCommittedEvent = parseAbiItem(
  "event ZombieConvertCommitted(uint256 indexed commitId, address indexed qualifyingWallet, uint256 indexed tokenId, uint256 index, address committer, address committedOwner)",
);
const ZombieConvertedEvent = parseAbiItem(
  "event ZombieConverted(uint256 indexed commitId, uint256 indexed tokenId, address indexed qualifyingWallet, uint256 poolIndex)",
);
const ZombieCommitCancelledEvent = parseAbiItem(
  "event ZombieCommitCancelled(uint256 indexed commitId, address indexed qualifyingWallet, uint256 indexed tokenId)",
);
const LegendaryCanvasSetEvent = parseAbiItem(
  "event LegendaryCanvasSet(uint256 indexed tokenId, string artistName, address indexed operator)",
);
const LegendaryCanvasClearedEvent = parseAbiItem(
  "event LegendaryCanvasCleared(uint256 indexed tokenId, address indexed operator)",
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
    NormiesMinterV2: {
      abi: [MintEvent],
      chain: chainName,
      address: requiredEnv("PONDER_MINTER_V2_ADDRESS") as `0x${string}`,
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
    NormiesZombieStorage: {
      abi: [ZombieAddedEvent, PoolSealedEvent, ZombieSetEvent],
      chain: chainName,
      address: requiredEnv("PONDER_ZOMBIE_STORAGE_ADDRESS") as `0x${string}`,
      startBlock: Number(
        process.env.PONDER_ZOMBIE_STORAGE_START_BLOCK ??
          process.env.PONDER_ZOMBIE_START_BLOCK ??
          startBlock,
      ),
    },
    NormiesZombie: {
      abi: [
        MerkleRootSetEvent,
        SeedBlockSetEvent,
        SeedLockedEvent,
        PausedSetEvent,
        ZombieConvertCommittedEvent,
        ZombieConvertedEvent,
        ZombieCommitCancelledEvent,
      ],
      chain: chainName,
      address: requiredEnv("PONDER_ZOMBIE_ADDRESS") as `0x${string}`,
      startBlock: Number(process.env.PONDER_ZOMBIE_START_BLOCK ?? startBlock),
    },
    NormiesLegendaryCanvas: {
      abi: [LegendaryCanvasSetEvent, LegendaryCanvasClearedEvent],
      chain: chainName,
      address: requiredEnv("PONDER_LEGENDARY_CANVAS_ADDRESS") as `0x${string}`,
      startBlock: Number(
        process.env.PONDER_LEGENDARY_CANVAS_START_BLOCK ?? startBlock,
      ),
    },
  },
});

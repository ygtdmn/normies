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
// Storage V2 carries setBy in the event: seeded delegations keep the owner who set them on the original canvas.
const DelegateSetV2Event = parseAbiItem(
  "event DelegateSet(uint256 indexed tokenId, address indexed delegate, address setBy)",
);
const DelegateRevokedEvent = parseAbiItem(
  "event DelegateRevoked(uint256 indexed tokenId, address indexed previousDelegate)",
);
const BurnCommittedEvent = parseAbiItem(
  "event BurnCommitted(uint256 indexed commitId, address indexed owner, uint256 indexed receiverTokenId, uint256 tokenCount, uint256 transferredActionPoints)",
);
// V2 adds toWallet: the reward and carried pixels go to the owner's wallet and receiverTokenId is 0.
const BurnCommittedV2Event = parseAbiItem(
  "event BurnCommitted(uint256 indexed commitId, address indexed owner, uint256 indexed receiverTokenId, uint256 tokenCount, uint256 transferredActionPoints, bool toWallet)",
);
const BurnRevealedEvent = parseAbiItem(
  "event BurnRevealed(uint256 indexed commitId, address indexed owner, uint256 indexed receiverTokenId, uint256 totalActions, bool expired)",
);
const PixelsTransformedEvent = parseAbiItem(
  "event PixelsTransformed(address indexed transformer, uint256 indexed tokenId, uint256 changeCount, uint256 newPixelCount)",
);
// Direct writes to the V1 storage (Option B — a bot writes straight to
// NormiesCanvasStorage, bypassing the canvas) emit NO event. We index the
// function call via call traces to capture them; see the handler in src/index.ts.
// The V2 storage emits on every write, so it needs no traces.
const SetTransformedImageDataFn = parseAbiItem(
  "function setTransformedImageData(uint256 tokenId, bytes imageData)",
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

// ──────────────────────────────────────────────
//  Pixel Market (V2 stack): storage V2 (overlays + pixel accounting), canvas V2, market
// ──────────────────────────────────────────────

const BalanceMovedEvent = parseAbiItem(
  "event BalanceMoved(address indexed from, address indexed to, uint256 amount)",
);
const AttachedChangedEvent = parseAbiItem(
  "event AttachedChanged(uint256 indexed tokenId, int256 delta, uint256 newAttached, uint8 reason)",
);
const TokenMigratedEvent = parseAbiItem(
  "event TokenMigrated(uint256 indexed tokenId, uint256 legacyAmount)",
);
const MoverRolesSetEvent = parseAbiItem(
  "event MoverRolesSet(address indexed mover, uint8 roles)",
);
const CanvasEnlargedEvent = parseAbiItem(
  "event CanvasEnlarged(uint256 indexed tokenId, uint256 fromSize, uint256 toSize, uint256 cost, uint8 source)",
);
const BaseClearedEvent = parseAbiItem(
  "event BaseCleared(uint256 indexed tokenId, uint256 cost, uint8 source)",
);
const TransformedImageDataSetEvent = parseAbiItem(
  "event TransformedImageDataSet(uint256 indexed tokenId, address pointer, uint256 length)",
);
const TransformClearedEvent = parseAbiItem(
  "event TransformCleared(uint256 indexed tokenId)",
);
const ListingCreatedEvent = parseAbiItem(
  "event ListingCreated(uint256 indexed listingId, address indexed seller, uint96 pricePerPixel, uint32 amount, bool partialFill, uint64 expiry)",
);
const ListingFilledEvent = parseAbiItem(
  "event ListingFilled(uint256 indexed listingId, address indexed buyer, address indexed seller, uint32 amount, uint32 remaining, uint256 grossWei, uint256 feeWei)",
);
const ListingCancelledEvent = parseAbiItem(
  "event ListingCancelled(uint256 indexed listingId, address indexed seller, uint32 refunded)",
);
const FeesPaidEvent = parseAbiItem(
  "event FeesPaid(uint256 treasuryWei, uint256 revenueShareWei)",
);
const FeeConfigSetEvent = parseAbiItem(
  "event FeeConfigSet(uint16 feeBps, uint16 revenueShareBps)",
);

// Revenue share: NormiesRevenuePool and NormiesRoyaltySplitter.
const EpochPostedEvent = parseAbiItem(
  "event EpochPosted(uint256 indexed epochId, bytes32 root, uint256 amount, uint64 fromBlock, uint64 toBlock, uint64 claimableAt, uint64 sweepableAt, bytes32 configHash, string dataURI)",
);
const RevenueClaimedEvent = parseAbiItem(
  "event Claimed(uint256 indexed epochId, uint256 indexed index, address indexed account, uint256 amount)",
);
const EpochSweptEvent = parseAbiItem(
  "event Swept(uint256 indexed epochId, uint256 returnedToPool)",
);
// A guardian withdrew an epoch before its claims opened: its reservation went back to the pool.
const EpochCancelledEvent = parseAbiItem(
  "event EpochCancelled(uint256 indexed epochId, uint256 returnedToPool, uint64 cursorToBlock)",
);
const RoyaltiesReleasedEvent = parseAbiItem(
  "event Released(uint256 toPool, uint256 toTeam)",
);

const pixelMarketStartBlock = Number(
  process.env.PONDER_PIXEL_MARKET_START_BLOCK ?? startBlock,
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
      // Optional: the mint window closed long ago; capping it keeps a local
      // fork backfill from scanning every later block for Mint events.
      ...(process.env.PONDER_MINTER_END_BLOCK
        ? { endBlock: Number(process.env.PONDER_MINTER_END_BLOCK) }
        : {}),
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
      startBlock: Number(process.env.PONDER_CANVAS_START_BLOCK ?? startBlock),
    },
    // Storage contract — indexed for its setTransformedImageData CALLS (traces),
    // so direct writes that skip the canvas still land in history. Default the
    // start block to the first known direct write to keep trace backfill small.
    NormiesCanvasStorage: {
      abi: [SetTransformedImageDataFn],
      chain: chainName,
      address: requiredEnv("PONDER_CANVAS_STORAGE_ADDRESS") as `0x${string}`,
      startBlock: Number(process.env.PONDER_CANVAS_STORAGE_START_BLOCK ?? startBlock),
      // Traces need debug_traceBlockByNumber, which Anvil forks do not serve:
      // set PONDER_CANVAS_STORAGE_TRACES=false there (V1 bot writes are then
      // not part of the local history).
      includeCallTraces: process.env.PONDER_CANVAS_STORAGE_TRACES !== "false",
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
    // ── Pixel Market ──
    NormiesCanvasV2: {
      abi: [
        BurnCommittedV2Event,
        BurnRevealedEvent,
        PixelsTransformedEvent,
        CanvasEnlargedEvent,
        BaseClearedEvent,
      ],
      chain: chainName,
      address: requiredEnv("PONDER_CANVAS_V2_ADDRESS") as `0x${string}`,
      startBlock: pixelMarketStartBlock,
    },
    NormiesCanvasStorageV2: {
      abi: [DelegateSetV2Event, DelegateRevokedEvent, BalanceMovedEvent, AttachedChangedEvent, TokenMigratedEvent, MoverRolesSetEvent, TransformedImageDataSetEvent, TransformClearedEvent],
      chain: chainName,
      address: requiredEnv("PONDER_CANVAS_STORAGE_V2_ADDRESS") as `0x${string}`,
      startBlock: pixelMarketStartBlock,
    },
    NormiesPixelMarket: {
      abi: [
        ListingCreatedEvent,
        ListingFilledEvent,
        ListingCancelledEvent,
        FeesPaidEvent,
        FeeConfigSetEvent,
        PausedSetEvent,
      ],
      chain: chainName,
      address: requiredEnv("PONDER_MARKET_ADDRESS") as `0x${string}`,
      startBlock: pixelMarketStartBlock,
    },
    NormiesRevenuePool: {
      abi: [EpochPostedEvent, RevenueClaimedEvent, EpochSweptEvent, EpochCancelledEvent],
      chain: chainName,
      address: requiredEnv("PONDER_REVENUE_POOL_ADDRESS") as `0x${string}`,
      startBlock: pixelMarketStartBlock,
    },
    NormiesRoyaltySplitter: {
      abi: [RoyaltiesReleasedEvent],
      chain: chainName,
      address: requiredEnv("PONDER_ROYALTY_SPLITTER_ADDRESS") as `0x${string}`,
      startBlock: pixelMarketStartBlock,
    },
  },
});

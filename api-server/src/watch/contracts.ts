/**
 * What the watcher looks at (mainnet). Every owner action on these contracts goes through the Admin Safe, so the Safe
 * executions cover the contracts that emit no event of their own (minters, renderers); the events below add what
 * changed, and catch anything that did not come from a Safe.
 */
export const SAFES: Record<string, string> = {
    [(process.env.ADMIN_SAFE ?? "0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa").toLowerCase()]: "Admin Safe",
    [(process.env.OPERATIONS_SAFE ?? "0x94afe25e744aEC9629cB67F63929fA4603898eB7").toLowerCase()]: "Operations Safe",
};

export const ADMIN_SAFE = Object.keys(SAFES)[0];

export const CONTRACTS: Record<string, string> = Object.fromEntries(
    Object.entries({
        NormiesCanvasStorageV2: "0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084",
        NormiesCanvasV2: "0xF14f2852e1fD6A4108156054AF49B3915dc40E2e",
        NormiesPixelMarket: "0x86156A8d6e4B9925F7fEca527ea5D71B0deeDB64",
        NormiesRendererV6: "0xd6747533697878a6a3a29B5cCf815740BA23998D",
        NormiesRevenuePool: "0x481384812e79bf0d11FC0b1704af445D5F06813c",
        NormiesRoyaltySplitter: "0xA68A225f62772E6158f2B5f8afC184AdB69c3282",
        Normies: "0x9Eb6E2025B64f340691e424b7fe7022fFDE12438",
        NormiesStorage: "0x1B976bAf51cF51F0e369C070d47FBc47A706e602",
        NormiesRenderer: "0xBe57fC4D0c729b8e8d33b638Dd441F57365e4c25",
        NormiesRendererV2: "0x7818f24d3239c945510e0a1a523dd9971812c6c0",
        NormiesRendererV3: "0x1af01b902256d77cf9499a14ef4e494897380b05",
        NormiesMinter: "0xC74994dD70FFb621CC514cE18a4F6F52124e296d",
        NormiesMinterV2: "0xc513272597d3022D77b3d7EEBA92cea5D7fb2808",
        NormiesCanvasStorage: "0xC255BE0983776BAB027a156681b6925cde47B2D1",
        NormiesCanvas: "0x64951d92e345C50381267380e2975f66810E869c",
        NormiesRendererV4: "0x8eC46Cc1f306652868a4dfbAAae87CBa2715A0eB",
        NormiesLegendaryCanvas: "0xfA55f6592522dA74224a67c7D3Fd1DF759c628e8",
        NormiesZombieStorage: "0xA331bD22C90D1DA096934Db8bc6b69F0e1491E26",
        NormiesZombie: "0x18533ad55a54c3847Da06A48b51aD7DcB2551202",
        NormiesRendererV5: "0x7c726f02C5e840e1656b522A5C22caaf87C1C35C",
    }).map(([name, address]) => [address.toLowerCase(), name]),
);

/** Known non-Normies addresses worth naming in a decoded call. */
export const KNOWN: Record<string, string> = {
    "0x40a2accbd92bca938b02010e17a5b8929b49130d": "Safe MultiSendCallOnly v1.3",
    "0x9641d764fc13c8b624c04430c7356c1c7c8102e2": "Safe MultiSendCallOnly v1.4.1",
    "0xa238cbeb142c10ef7ad8442c6d1f9e89e07e7761": "Safe MultiSend v1.3",
    "0x38869bf66a61cf6bdb996a6ae40d5853fd43b526": "Safe MultiSend v1.4.1",
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": "WETH",
    "0xa6d95197d990afb92675d6f28cae7982e5935915": "revshare poster key",
};

export const nameOf = (address: string) => {
    const a = address.toLowerCase();
    return SAFES[a] ?? CONTRACTS[a] ?? KNOWN[a] ?? address;
};

export type Severity = "urgent" | "notice";

/**
 * The events watched, by severity. "urgent" mentions DISCORD_MENTION: ownership, roles, writers, money routes and
 * epochs, which should only ever happen when you did them yourself. "notice": operating changes (pauses, prices).
 * High-volume user events (transfers, burns, listings, claims) are not watched.
 */
export const WATCHED_EVENTS: Record<string, Severity> = {
    // ownership and access
    OwnershipTransferred: "urgent",
    OwnershipHandoverRequested: "urgent",
    OwnershipHandoverCanceled: "notice",
    RolesUpdated: "urgent",
    MoverRolesSet: "urgent",
    AuthorizedWriterSet: "urgent",
    CooldownSet: "urgent",
    // money routes and the pool
    FeeRecipientsSet: "urgent",
    TeamSet: "urgent",
    PoolBpsSet: "urgent",
    Withdrawn: "urgent",
    EpochPosted: "urgent",
    EpochCancelled: "urgent",
    DefaultRoyaltySet: "urgent",
    TokenRoyaltySet: "urgent",
    // the NFT and the old contracts
    MinterAddressSet: "urgent",
    TransferValidatorUpdated: "urgent",
    AutomaticApprovalOfTransferValidatorSet: "urgent",
    RevealHashSet: "urgent",
    MerkleRootSet: "urgent",
    SeedBlockSet: "urgent",
    ZombieAdded: "urgent",
    ZombieSet: "urgent",
    // operating changes
    PausedSet: "notice",
    AllowancesPausedSet: "urgent",
    FeeConfigSet: "notice",
    MinPricePerPixelSet: "notice",
    EnlargePriceSet: "notice",
    BlankCanvasPriceSet: "notice",
    BurnTiersSet: "notice",
    MaxBurnPercentSet: "notice",
    ClaimWindowSet: "notice",
    LegendaryCanvasSet: "notice",
    LegendaryCanvasCleared: "notice",
    BatchMetadataUpdate: "notice",
    // the Safes themselves
    ExecutionSuccess: "notice", // upgraded to urgent for the Admin Safe
    ExecutionFailure: "notice",
    AddedOwner: "urgent",
    RemovedOwner: "urgent",
    ChangedThreshold: "urgent",
    EnabledModule: "urgent",
    DisabledModule: "urgent",
    ChangedGuard: "urgent",
    ChangedModuleGuard: "urgent",
    ChangedFallbackHandler: "urgent",
    ExecutionFromModuleSuccess: "urgent",
    ExecutionFromModuleFailure: "urgent",
};

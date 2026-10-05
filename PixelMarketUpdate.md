# Pixel Market cutover runbook

## What Pixel Market is

Burning a Normie earns action points, a budget attached to a surviving Normie that sets how far its art
may differ from the original. Pixel Market turns those points into #PIXEL, a tradable unit: one point,
one #PIXEL, one pixel of on-chain art. #PIXEL is never minted or sold by the team; the only way it enters
the world is a burn. A holder can take #PIXEL off a Normie into their wallet, list it for ETH, buy some
and put it on a Normie they own. Every fill pays a fee, half of which goes to a revenue pool that pays
holders in epochs by a score built from the Normies and #PIXEL they hold, alongside half of the
collection's OpenSea royalties. Spending #PIXEL on canvas services burns it out of circulation.

Launch is buying and selling. The canvas keeps what it does today, burn and paint, and gains the rest
with the same deploy: withdrawing #PIXEL from a Normie and depositing it back, burning straight to the
wallet, enlargement to 50 to 80 pixels per side and the blank canvas. Everything after that is priced in #PIXEL
and comes later: a wheel raffle paying out #PIXEL and Normies, commissioned physical murals, merch, and a
Canvas V3 whenever one is needed, which storage V2 makes a deploy plus a role grant. Nothing in this
document needs those; it covers the cutover from the original canvas to the V2 stack.

## What the cutover does

Deploys the V2 stack (storage V2 with the pixel accounting, canvas V2, market, renderer V6, revenue pool,
royalty splitter), moves the live renderer over, and retires the V1 canvas. State moves once: after V1 is paused storage V2 copies every
V1 balance and every V1 delegation into storage V2 (`MigrateLegacy.s.sol` reading V1 itself, and the TypeScript
`pnpm cutover:delegations` taking a fixed-block snapshot from V1's events and copying/sealing it in one
transaction), both copies are then closed; storage V2 reads V1 overlays until a token
is written again. Canvas V2 and renderer V6 hold no per-token state and no reference to V1, so a later canvas or
renderer is a deploy plus a role grant, with nothing to copy. V1 has no replay path on V2, so every V1 commitment must be revealed
before V1 is paused.

## Contracts

One repo, one deploy script. Storage V2 holds the data (overlays and pixel balances) so the logic contracts can be
replaced later without moving anything.

| Contract | Role |
| --- | --- |
| `NormiesCanvasStorageV2` | All per-token canvas data: overlays of any grid size (emits on every write, falls back to V1 storage), grid size, blank-base flag, Canvas delegate (a V1 snapshot copied and sealed atomically by `seedAndFinalizeDelegations`), and the pixel accounting: wallet and per-Normie balances, every pixel the same. Mover roles: CanvasV2 (`ROLE_CANVAS`, the only one that changes supply), Market (`ROLE_MARKET`) and a future wrapper (`ROLE_WRAPPER`) can only move wallet balances. Overlay writers (`authorizedWriters`, incl. the everyday bot) cannot touch pixels. V1 balances are copied in once by `migrateBatch` and closed with `finalizeMigration`. |
| `NormiesCanvasV2` | Burns (onto a Normie, or straight to the wallet with `commitBurnToWallet`), painting, withdraw/deposit between a Normie and its owner's wallet (vault delegates also need a pixel allowance for deposits), enlargement and blank canvas, whose pixels are burned out of circulation. |
| `NormiesPixelMarket` | Sell-side listings (`list`, or `listFrom` with an allowance), ETH per pixel above `minPricePerPixel`, `buy` or `batchBuy` for several listings in one transaction. Once a listing with an expiry has expired, anyone can `reclaimExpired` it: the unsold pixels go back to the seller only, without a cooldown. The fee comes out of seller proceeds and is paid in the fill's transaction (`FeesPaid`), half to the treasury and half to the revenue pool; nothing accrues in the market. |
| `NormiesRendererV6` | Grid-aware renderer with `Canvas Size` and `Blank Canvas` traits. |
| `NormiesRevenuePool` | Holds the holders' share of market fees and royalties. Epoch Merkle roots posted by the POSTER role, claims with proofs from `POST_DELAY` (24 hours) after posting, until when a guardian can `cancelEpoch`; an immutable per-epoch sweep deadline (the claim window, at least 30 days, a year by default), unclaimed rolls back into the pool; the owner can withdraw only what no epoch has reserved. |
| `NormiesRoyaltySplitter` | Royalty receiver. Permissionless `release()` unwraps WETH and splits ETH between the pool (`poolBps`, launch 5000) and the team. |

Invariants worth knowing before touching anything:

- Pixels are only ever spent by their holder or by a wallet the holder approved
  (`storageV2.approve(spender, amount)`, ERC20-style, `type(uint256).max` never decreases). Deposits,
  enlargement and blank canvas paid from the wallet or from the token, and `market.listFrom(seller, ...)`
  consume that allowance when the caller is not the holder. An allowance is custody of that amount: an
  approved wallet can list the pixels at any price and fill the listing itself, so approve exact amounts
  and revoke afterwards. No delegation of any kind reaches a balance.
- Allowance kill switch: `storageV2.setAllowancesPaused(true)` (owner or GUARDIAN) stops every third-party allowance use
  at once (delegate deposits and paid services, `listFrom`). Holders acting for themselves are unaffected and
  can still change or revoke allowances while paused; lift it with `setAllowancesPaused(false)`.
- Wallet pixels cool down. Pixels withdrawn from a Normie, bought on the market or handed back by a cancel
  wait `DEFAULT_COOLDOWN` (one minute) before they can be deposited, listed or spent
  (`storageV2.availableBalance`, `lockedBalance`, `unlockAt`; a blocked spend reverts `PixelsCoolingDown`).
  Pixels already past their cooldown stay spendable while new arrivals wait. Each arrival restarts the clock for
  everything still cooling in that wallet, so the whole cooling amount unlocks one cooldown after the latest
  arrival. Today only the wallet itself causes arrivals that cool (its own withdrawals, purchases and cancels), so
  nobody else can extend it; any future mover (a wrapper) must keep it that way. Burn rewards minted to a wallet
  and the balances of movers (the market) never cool.
- `setCooldown` is for wrapper contracts only, never a person's wallet. It raises one address's
  cooldown between the default and `MAX_COOLDOWN` (seven days). On an address that keeps receiving pixels more
  often than its cooldown, everything it received stays locked until a full cooldown passes with nothing new
  arriving, which for an active buyer on seven days can be never. The contract accepts any address, so this rule
  is the guard: it is an owner action that only the Admin Safe can send, and `CooldownSet` is on the alert list.
  Undo a mistake with `setCooldown(account, 0)`, which restores the default.
- Listings have a floor: `market.minPricePerPixel` (0.0018 ETH at deployment, about five dollars; replace
  it with `setMinPricePerPixel` as ETH moves). It exists so a 1 wei listing cannot be a fee-free transfer.
- Two kinds of delegate, both paint-only. A Canvas delegate (`setDelegate`, or one copied from V1 at cutover)
  and a delegate.xyz delegate (V1 `0x0000…638B` or V2 `0x0000…d493`; wallet, contract or token level with full
  rights) can `setTransformBitmap` and nothing else: no `withdrawPixels`, no deposits, no paid services, no burns,
  no listings, no Canvas delegation. Taking pixels off a Normie is the owner's alone. Putting pixels on, `enlargeCanvas`
  and `clearBase` (from the wallet or from the token) and `market.listFrom` are open to the owner or to any wallet
  the owner approved for the amount, delegate or not; the canvas books every pixel against the owner's wallet and
  a non-owner with a zero allowance is refused even for a free service.
  Check `forge build --sizes` before deploying: `NormiesCanvasV2` is 22,680 bytes, about 1,900 under the
  24,576-byte limit.

- Pixels attached to a Normie are a ceiling, never spent by painting. Withdrawing or spending below
  the overlay's popcount resets the overlay, and only with `clearOverlay = true`.
- **Delegation snapshot boundary:** `pnpm cutover:delegations` (in `api-server`, source
  `src/cutover/migrate-delegations.ts`) finds every token that ever had a delegate from V1's `DelegateSet`
  events, reads each one's current delegate and setter at one snapshot block (the head, or `--block`), and
  broadcasts exactly one `seedAndFinalizeDelegations` transaction: all records and the seal succeed together,
  or none do. The snapshot block and its timestamp are saved as `delegationSnapshotBlock` /
  `delegationSnapshotTimestamp` on storage V2. V1 delegation changes after that block are intentionally
  ignored. It refuses unless the balance migration is finalized, the copy is still open and V1 is paused.
  `--dry-run` prints the records without sending. Env: `RPC_URL`, `CHAIN_ID`, `CANVAS_STORAGE_V2_ADDRESS`,
  `PRIVATE_KEY` (the storage owner; or `FROM` on anvil), optional `CANVAS_V1_DEPLOY_BLOCK`. It runs in seconds
  where the old Solidity scan took minutes; a rehearsal at block 25,999,628 found 82 records and the
  copy-and-seal used about 3.96 million gas.
- The V1 canvas must stay paused after cutover. Storage V2 never reads it again once the migration
  is finalized, so anything earned there afterwards is lost. `script/ResumeCanvas.s.sol` refuses
  without `RESUME_V1_CANVAS=true`.
- **Zombies are a completed campaign: all 21 are already claimed. There will be no new conversions.**
  Retain `NormiesZombie` at `0x18533ad55a54c3847Da06A48b51aD7DcB2551202` and its storage at
  `0xA331bD22C90D1DA096934Db8bc6b69F0e1491E26` exactly as they are. Do not redeploy either contract,
  migrate claims, change the root/seed/permutation, or alter writer permissions as part of this cutover.
  Canvas V2 and renderer V6 must both read the existing zombie contract. The existing token-to-pool
  assignments have no removal or replacement API: the same 21 tokens retain their zombie identity,
  assigned base art and traits. V1's immutable level check is only for new conversion commitments;
  it does not affect recognition or rendering of already-converted zombies.
- `DeployPixelMarket.s.sol` performs a read-only zombie preflight before broadcasting: the original
  contract/storage and collection must match, all 21 claim slots must have revealed with matching
  assignments and consumed claims, and no commitment may still be pending. A failure stops deployment;
  investigate the configuration instead of replacing or reopening the converter. No zombie state is
  written by the deployment. Existing holder canvas behavior is unchanged.

## 1. Rehearse on a fork

`NormiesCanvasV2` is 22,680 bytes against the 24,576-byte runtime limit (about 1,900 bytes of headroom).
Check `forge build --sizes` before any deploy; a contract over the limit makes `forge script` fail before
broadcasting.

```bash
cd smart-contracts
anvil --fork-url "$MAINNET_RPC" --chain-id 31337 &
export NORMIES_ADDRESS=0x9Eb6E2025B64f340691e424b7fe7022fFDE12438
export STORAGE_ADDRESS=0x1B976bAf51cF51F0e369C070d47FBc47A706e602
export CANVAS_ADDRESS=0x64951d92e345C50381267380e2975f66810E869c
export CANVAS_STORAGE_ADDRESS=0xC255BE0983776BAB027a156681b6925cde47B2D1
export ZOMBIE_ADDRESS=0x18533ad55a54c3847Da06A48b51aD7DcB2551202
export LEGENDARY_CANVAS_ADDRESS=0xfA55f6592522dA74224a67c7D3Fd1DF759c628e8
export FEE_TREASURY=<team ETH wallet>
export ROYALTY_TEAM=<team wallet for its half of royalties>
export EXTRA_STORAGE_WRITER=<beeple bot, optional>
forge script script/DeployPixelMarket.s.sol --rpc-url localhost --broadcast --sender <deployer> --unlocked
export CANVAS_STORAGE_V2_ADDRESS=<from the broadcast>
# copy the V1 balances in and finalize
forge script script/MigrateLegacy.s.sol --rpc-url localhost --broadcast --sender <deployer> --unlocked
# copy the V1 delegations in and seal (same CANVAS_STORAGE_V2_ADDRESS; FROM is the unlocked deployer on anvil)
(cd api-server && RPC_URL=http://127.0.0.1:8545 CHAIN_ID=31337 FROM=<deployer> pnpm cutover:delegations)
```

`script/local-pixel-market-stack.sh up` does all of this on a pinned fork, plus indexer, API and site, with
two shortcuts: the balance migration takes its candidate ids from V1's `BurnRevealed` events (`TOKEN_IDS`)
instead of scanning 10,000 ids, and the delegation copy runs through `pnpm cutover:delegations`. The seed listing
is placed at 0.002 ETH, above the floor, after jumping the clock past the cooldown. Both deploys and the
market start paused; the stack unpauses them after the copies are finalized.

The fork test `test/NormiesPixelMarketForkTest.t.sol` does the same wiring in-process against
mainnet state and is part of `forge test` when `API_KEY_ALCHEMY` is set.

Point the indexer at the fork (`indexer/.env.local.anvil`: `PONDER_CANVAS_V2_ADDRESS`,
`PONDER_CANVAS_STORAGE_V2_ADDRESS`, `PONDER_MARKET_ADDRESS`, `PONDER_REVENUE_POOL_ADDRESS`,
`PONDER_ROYALTY_SPLITTER_ADDRESS` and `PONDER_PIXEL_MARKET_START_BLOCK` from the broadcast) and the API
server at the indexer (`api-server/.env`: `CANVAS_V2_ADDRESS`, `CANVAS_STORAGE_V2_ADDRESS`, `MARKET_ADDRESS`,
`REVENUE_POOL_ADDRESS`, `ROYALTY_SPLITTER_ADDRESS`, `REVSHARE_DIR`). Run a scripted scenario and check every surface:

1. Burn fodder into a token on V2; `/canvas/token/:id/pixels` shows the attached balance.
2. Paint on a 60x60 canvas after `enlargeCanvas`; `/normie/:id/image.svg` renders `viewBox 0 0 60 60`
   and `/history/normie/:id/versions` reports `gridSize: 60`.
3. `withdrawPixels` with `clearOverlay = true`; the version list gains a `cleared: true` row and
   `/pixels/balance/:address` shows the wallet balance.
4. `list` at or above the floor, a partial `buy`, a `batchBuy` over two listings, `cancel`; `/market/listings`,
   `/market/fills`, `/market/stats` agree with the contract, `storageV2.balanceOf(market)` equals the sum of
   open `remaining`, the fee recipients' balances grew with each fill and the market holds no ETH.
   Bought pixels show up in `availableBalance` only after a minute.
5. `clearBase`; `/normie/:id/metadata` shows `Blank Canvas: Yes` and matches `tokenURI`.
6. The handoff, against the real Safes (create them on mainnet first; the fork has them): mainnet step 5 with
   `--rpc-url` pointed at the fork and `--unlocked --sender <deployer>`, then the `MODE=check` run with
   `DEPLOY_BLOCK` and `NORMIES_ADDRESS` after step 10's two calls from the impersonated Normies owner. This is
   the first real run of the role-event replay, so check it reads the fork's logs.
7. The stolen-key drill ("A post nobody expected" under Ownership): post from the poster key, then the
   Operations Safe's cancel and pause MultiSend and the Admin Safe's `revokeRoles`, executed through the Safe
   app against the fork or with impersonated signers.

## 2. Mainnet

Order matters. Deploying early is safe: every V2 contract starts paused and empty, nothing reads V1 at
deployment, and the setup calls are owner-only. Do not migrate before pausing V1 (`migrateBatch` refuses anyway).
If you deploy hours before launch, set `REVSHARE_GENESIS_BLOCK` to the launch block, not the deployment block, so the
first epoch does not score the hours before launch.

1. **Drain V1.** Reveal every unrevealed V1 commitment (permissionless):
   `GET /history/burns/pending/legacy` lists them once the indexer is on the new schema; before
   that, iterate `nextCommitId()` and read `burnCommitments(id).revealed`. Nothing can claim a
   commitment left unrevealed after V1 is paused: there is no replay on V2. `MigrateLegacy.s.sol`
   refuses to run while one exists.
2. **Pause V1.** `MigrateLegacy.s.sol` does it from the V1 owner key when it finds V1 unpaused (it then
   stops; rerun it to migrate), or do it by hand with `NormiesCanvas.setPaused(true)`. Storage V2's
   `migrateBatch` refuses while V1 is unpaused, and neither Canvas V2 nor the market can be unpaused
   until the required copies are finalized.
3. **Deploy.** `forge script script/DeployPixelMarket.s.sol --rpc-url mainnet --broadcast --verify`
   with the env above. The script wires movers, writers, treasury, fee recipients and renderer
   references, then leaves CanvasV2 and the market paused. The deployer key signs from a trusted workstation
   (a hardware wallet, `--ledger`), never from the API server, and owns nothing once step 5 is done. Then, from
   the deployer,
   `forge script script/MigrateLegacy.s.sol --rpc-url mainnet --broadcast` with
   `CANVAS_STORAGE_V2_ADDRESS`: it refuses while any V1 commitment is unrevealed, pauses V1 itself if
   needed (then stops; rerun), scans all 10,000 ids, copies every nonzero V1
   balance into storage V2 in batches of `BATCH` (storage V2 reads V1 itself) and finalizes. Finalizing is a hard
   gate: the script sums V1 `actionPoints` over every id and `finalizeMigration(expected)` refuses
   unless `storageV2.totalAttached()` equals exactly that sum (37,805 at block 25,999,628; 40,315 at block
   26,107,972). On mainnet the script refuses `TOKEN_IDS` and any `MAX_TOKEN_ID` below 9999, so the sum always
   covers every id. Check the printed total and `migrationFinalized() == true`.
   Then, in `api-server`, `pnpm cutover:delegations --dry-run` and, when the list looks right,
   `pnpm cutover:delegations` with `RPC_URL`, `CHAIN_ID=1`, `CANVAS_STORAGE_V2_ADDRESS` and `PRIVATE_KEY`
   (the storage owner, still the deployer at this point; run it on the same workstation and do not leave the key
   in any env file afterwards): takes the delegation snapshot at the current block, then copies every nonzero V1
   delegate and its original setter and seals seeding in one transaction.
   Check `storageV2.delegationsSeeded() == true`, the saved snapshot block/timestamp, and a known delegate.
   After this snapshot, only V2 delegation changes matter. The balance preparation above is separate;
   the delegation copy-and-seal itself is atomic.
4. **Verify wiring** on Etherscan: `storageV2.moverRoles(canvasV2) == 1`, `(market) == 2`;
   `storageV2.authorizedWriters(canvasV2)` (+ the bot); `storageV2.allowancesPaused() == false`;
   `storageV2.DEFAULT_COOLDOWN() == 60`, `migrationFinalized()`, `delegationsSeeded()`;
   `canvasV2.canvasStorage()`, `zombieContract()`, `paused() == true`;
   `market.pixels()`, `treasuryRecipient()`, `revenueShareRecipient() == revenuePool`, `feeBps() == 1000`,
   `revenueShareBps() == 5000`, `minPricePerPixel() == 1800000000000000`, `paused() == true`;
   `pool.claimWindow() == 31536000`, `MIN_CLAIM_WINDOW() == 2592000`, `POST_DELAY() == 86400`;
   every `owner()` is still the deployer at this point;
   `splitter.pool()`, `splitter.team()`, `splitter.poolBps() == 5000`;
   `rendererV6.transformStorageContract()`, `zombieContract()`, `legendaryCanvasContract()`.
5. **Hand off ownership.** Before anything is unpaused, the deployer stops owning anything. The two Safes (see
   "Ownership" below) must exist with a harmless transaction run from each. Pick the revshare job's gas-only key
   (`REVSHARE_POSTER`). Then, from the deployer: `forge script script/HandoffOwnership.s.sol --rpc-url mainnet
   --broadcast` (signing with the deployer key) with the six contract addresses (`CANVAS_STORAGE_V2_ADDRESS`,
   `CANVAS_V2_ADDRESS`, `MARKET_ADDRESS`, `RENDERER_V6_ADDRESS`, `REVENUE_POOL_ADDRESS`,
   `ROYALTY_SPLITTER_ADDRESS`), `ADMIN_SAFE`, `OPERATIONS_SAFE` and `REVSHARE_POSTER` (`TREASURY_SAFE` left unset:
   the Admin Safe owns the pool and splitter too). It refuses unless both copies are finalized, the deployer holds
   no mover role or writer slot, the wiring is right, the Operations Safe and the poster are separate from the
   owner, and the Safes are real multisigs (Admin needs at least 3 signatures, Operations at least 2, different
   signer sets, and the poster key a signer of none). It then grants the roles, locks the deployer's Lifebuoy rescue access and hands every contract
   to its Safe. Each step is skipped when already done: if a run stops half way, rerun it. Then
   `MODE=check DEPLOY_BLOCK=<step 3's first block> DEPLOYER=<deployer> EXTRA_WRITERS=<bot key> forge script
   script/HandoffOwnership.s.sol --rpc-url mainnet` (same env) must print "handoff verified". Besides the current
   state it replays every role, mover and writer event since `DEPLOY_BLOCK`, so a role held by anyone outside this
   layout fails it (the RPC must serve `eth_getLogs` over that range). Paste the output here: it ends with the fee
   and royalty recipients and each Safe's threshold. Still look at each Safe's signer list in the Safe app: the
   script checks the thresholds and that the sets differ, not who the people are.
6. **Renderer flip.** From the Normies owner: `setRendererContract(rendererV6)`. Spot check
   `tokenURI` for token 0 (bot overlay), a token with AP, and a zombie.
7. **Indexer + API.** Set the three addresses and the start block, deploy the indexer (new schema,
   full reindex), then the API server with the three addresses. Confirm `/canvas/status` returns
   `pixelMarket`, `/pixels/supply` answers, `/market/stats` answers.
8. **Site.** Set `NEXT_PUBLIC_CANVAS_V2_ADDRESS`, `NEXT_PUBLIC_CANVAS_STORAGE_V2_ADDRESS`,
   `NEXT_PUBLIC_MARKET_ADDRESS`, `NEXT_PUBLIC_REVENUE_POOL_ADDRESS`, deploy. Update the
   constants in `src/lib/contracts.js`, the address tables in `api-server/src/content/*` and
   `src/views/Docs.jsx` afterwards.
9. **Royalties.** From the Normies owner: `setRoyaltyInfo(royaltySplitter, 500)`. OpenSea does not read
   ERC2981 for the payout address: set the splitter as the payout address under the collection's
   Creator Earnings too, then make one cheap test sale and check the splitter received it (listings
   pay ETH mid-sale, accepted offers pay WETH; `release()` handles both). Check Blur and Magic Eden.
10. **Normies owner to the Admin Safe.** After steps 6 and 9, from the current Normies owner key:
    `normies.lockRescue(1)` (locks the deployer's Lifebuoy access), then `normies.transferOwnership(adminSafe)`.
    This is a one-step transfer, so paste the Admin Safe address from step 5's output, never by hand. From then
    on renderer, royalty, minter and validator changes are Admin Safe transactions, and no single key can mint a
    burned id again (audit C-H1). OpenSea and the other marketplaces: connect the Admin Safe (WalletConnect from the
    Safe app) to edit the collection. Rerun step 5's check with `NORMIES_ADDRESS` set; it must still print
    "handoff verified".
11. **Unpause, from the Operations Safe.** Pausing and unpausing are GUARDIAN actions with no delay:
    `canvasV2.setPaused(false)` (refused until `migrationFinalized()` and `delegationsSeeded()`), then
    `market.setPaused(false)` (refused until `migrationFinalized()`). The first live state is already under the
    Safes.
12. **Revenue share job.** Install `deploy/revshare/` with `PRIVATE_KEY` = the `REVSHARE_POSTER` key: it holds
    the pool's POSTER role and nothing else. See "Running a revenue share epoch".
13. **Holders.** Announce that the canvas needs a fresh `setApprovalForAll(canvasV2, true)` before
    burning; the site prompts for it.
14. **Beeple bot.** Switch its writes to StorageV2 and to the right bitmap length for token 0's
    grid size (200 bytes while it stays 40x40).

## Ownership

No single key holds an owner power, the guardian is its own Safe with its own signers, and no owner key lives on an
internet-facing machine. At launch one Safe, the Admin Safe (`0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa`, 3-of-5),
owns every contract, including the revenue pool and the royalty splitter; the Operations Safe
(`0x94afe25e744aEC9629cB67F63929fA4603898eB7`, 3-of-5, other signers) holds GUARDIAN and CONFIG. The handoff
script also accepts a separate `TREASURY_SAFE` for the pool and splitter, if that is ever wanted. Storage V2,
canvas V2, the market and the pool use Solady `OwnableRoles` through `NormiesAccess`; the splitter and renderer V6
use Solady `Ownable`. Later ownership moves use the two-step handover (`requestOwnershipHandover` /
`completeOwnershipHandover`).

| Holder | Who | Holds | What it can do |
| --- | --- | --- | --- |
| Admin Safe | 3-of-5, hardware wallets, at least 3 people | owner of storage V2, canvas V2, market, renderer V6, revenue pool, royalty splitter, and the Normies NFT (step 10). Also receives the team's half of fees and royalties | Mover roles, overlay writers, cooldowns, role grants, fee recipients, contract pointers, ownership; on the pool: withdraw ETH no epoch has reserved; on the splitter: the royalty split and the team address; on the NFT: renderer, royalties, minters |
| Operations Safe | 2-of-3, different people | GUARDIAN on storage V2, canvas, market, pool; CONFIG on canvas, market, pool | Pause and unpause anything at once, the allowance kill switch (both ways), cancel an epoch before it opens. Config: prices, burn tiers, fee (at most 10%), listing floor, claim window (at least 30 days). Can never grant roles or withdraw ETH or #PIXEL, but can still cost holders: see below |
| Revshare job key | EOA on the API host, gas only | POSTER on the pool | `postEpoch` only. Claims open 24 h later, so a bad root can be cancelled by the Operations Safe |
| Overlay bot key | EOA | an `authorizedWriters` slot | Overlays only; it cannot move pixels |
| Deployer | hardware wallet | nothing after step 5 | Retired; no roles, Lifebuoy rescue locked |

Owner actions take effect as soon as the Admin Safe executes them; there is no timelock. Its threshold is the whole
protection: a quorum of its signers controls both the #PIXEL roles and the ETH no epoch has reserved yet (what a
posted epoch owes can never be withdrawn). So its signers stay on hardware wallets, and every Admin Safe transaction
is on the alert list. A compromised revshare key can post a root that the Operations Safe
cancels before it opens (see "A post nobody expected" below).

The Operations Safe cannot withdraw ETH or #PIXEL, but two of its powers can still cost holders, so treat its
signatures with the same care. CONFIG can lower the burn tiers or `maxBurnPercent` after someone has committed a
burn: the reveal reads the live values, so that burn pays less, down to nothing (audit C-L1). Only change burn
parameters when `pendingBurnCommitments` is empty. GUARDIAN can keep the canvas paused for more than about 50
minutes, after which every unrevealed burn pays its tier minimum (audit D-L2). Only pause the canvas on purpose
when no burn is pending, and keep an emergency pause short.

The Normies NFT owner (renderer, royalty receiver, minters) moves to the Admin Safe in step 10. Until then it is a
plain key: keep it offline, because remints of burned ids are only possible from that owner.

Signers: hardware wallets only, never 1-of-N, different people across the three Safes. Write down who can pause
what and practice it once on a fork, including an epoch cancel. Review the signer list whenever someone leaves.

**Monitoring.** Alert on every one of these; each should be expected, so a surprise is an incident. On the three
Safes: every executed transaction and every owner or threshold change. On the V2 contracts: `OwnershipTransferred`,
`OwnershipHandoverRequested`, `RolesUpdated`, `MoverRolesSet`, `AuthorizedWriterSet`, `CooldownSet`,
`AllowancesPausedSet`, `FeeRecipientsSet`, `FeeConfigSet`, `MinPricePerPixelSet`, `EnlargePriceSet`, `BurnTiersSet`,
`MaxBurnPercentSet`, `PoolBpsSet`, `TeamSet`, `EpochPosted`, `EpochCancelled`, `Withdrawn`, `ClaimWindowSet`,
`PausedSet`. An owner action nobody expected means the Operations Safe pauses first and the signers find out why.
`EpochPosted` pages someone (a phone, not only a channel), and so does a failed `normies-revshare.service` run;
see the next section.

**A post nobody expected (stolen POSTER key).** A cancel alone does not stop a stolen poster key: the cancelled
range comes back, and the key can post it again in the next block, reserving everything unreserved once more. The
24 hours before claims open are the whole defence, so:

1. Any `EpochPosted` that the revshare job's journal does not show it posting is treated as a stolen key.
2. The Operations Safe sends one MultiSend: `pool.cancelEpoch(id)` and `pool.setPaused(true)`. Pausing stops
   posting; claims on already open epochs are never paused.
3. The Admin Safe (the pool's owner) revokes the role: `pool.revokeRoles(<poster>, 4)`. Stop the timer on the API host and
   rotate the key: a new gas-only key, `grantRoles(<new key>, 4)` from the Admin Safe, the new key in
   `/etc/normies/revshare.env`.
4. The Operations Safe unpauses the pool; the next run posts the cancelled range again under a new id.

At least two Operations signers must be able to sign within a day, weekends included. Practise steps 2 and 3 once
on a fork before launch.

## Running a revenue share epoch

The pool pays in epochs. Scores need what every wallet held over time, which no contract can see, so
`api-server/src/revshare` computes them from RPC state and the pool stores only a Merkle root.

A posted root opens for claims `POST_DELAY` (24 hours) later; until then the Operations Safe can `cancelEpoch`,
which returns its reservation and, for the latest epoch, its block range. Once open it pays out and cannot be
taken back. So posting always follows the same order and stops at the first thing that is not
right: **release, unwrap, wait for finality, build, verify on a second RPC, re-check the pool, post, read back.**
The tooling enforces the order; the rules are in `api-server/src/revshare/guards.ts`.

On the server this is a monthly systemd timer, `deploy/revshare/` (units, env example, install and operating
notes). `pnpm revshare run` does the whole sequence and refuses to post without `RPC_URL_VERIFY`, an independent
second provider (not the same endpoint as `RPC_URL`). Its key holds the pool's POSTER role and nothing else:

1. `splitter.release()` and `pool.unwrap()` when they hold anything, so the epoch holds everything earned in it.
   Market fees need no step: every fill pays its half into the pool.
2. The epoch ends at the chain's finalized block, and at least `EPOCH_FINALITY_BLOCKS` below the head, after the
   release and unwrap blocks. ETH that arrives after the epoch's end belongs to the next epoch.
3. Builds the epoch: four unpredictable sample blocks per UTC day, every wallet scored at each; the amount is
   what the pool held unpromised at the end block, the posted `total` is the sum of the leaves (dust stays).
4. Rebuilds it from scratch on the second RPC (its own amount, samples and scores) after checking both
   providers return the same hash for the end block. Any difference in id, range, amount, total, config,
   samples or root stops the run.
5. Re-reads the pool right before posting: not paused, the epoch id is still `nextEpochId`, the range starts
   right after the last posted epoch, and the total still fits what is unreserved.
6. Posts only once the previous epoch's claims are open. A cancel hands back only the latest range, so with two
   unopened epochs, cancelling both would strand the older range for good; an early run just stops. Then it
   posts, reads `getEpoch(id)` back and prints when claims open. In the 24 hours before that, anyone can run
   `pnpm revshare verify <file>` (the file is public at its `dataURI`) on their own RPC; the Operations Safe
   cancels with `cancelEpoch(id)` if anything is off, and the next run posts the range again under a new id.
7. A key without the POSTER role (or a pool not yet handed off) gets `REVSHARE_DIR/proposals/<id>.safe.json`
   instead, a Safe Transaction Builder batch for the pool owner; later runs leave a pending proposal alone until
   the pool shows it posted (`--replace-proposal` rebuilds it). Both cases exit with code 2 (`ACTION NEEDED` in
   the journal), so the unit fails and pages: after the handoff the job should never be waiting on a Safe.

By hand (for example when the post goes through a Safe), the same order:

1. `splitter.release()` and `pool.unwrap()` (both permissionless). Wait until both blocks are finalized.
2. `pnpm revshare build --epoch <pool.nextEpochId()> --from <pool.cursorToBlock() + 1> --to <finalized block>` in
   `api-server` (archive `RPC_URL`, `CHAIN_ID` and the contract addresses in env, see `src/revshare/cli.ts`).
   `--epoch` is required: the leaves embed it, and an id that moves before the post makes every leaf unclaimable.
3. `RPC_URL=<second provider> pnpm revshare verify <file>`. It rebuilds the file (amount included) and checks it
   is postable now; it must print both "verified" and "postable". Every Safe signer runs it on their own RPC
   before signing.
4. Copy the file to `/var/lib/normies-revshare/epochs/<id>.json` on the indexer host; the API then serves it at
   `https://api.normies.art/revshare/files/<id>.json`, which is the `dataURI` to post. Then send the
   printed `postEpoch(...)` call from the POSTER key. Holders claim from the site (or `claimMany`) once it opens,
   24 hours later.
5. `pnpm revshare verify <file>` once more: for a posted epoch it checks the pool recorded exactly the file.

At that epoch's fixed `getEpoch(id).sweepableAt` anyone can `sweep(id)`: unclaimed ETH returns to the pool for later
epochs. Each epoch snapshots the default window when posted (365 days at launch), counted from its opening.
`setClaimWindow` (CONFIG) affects future epochs only and requires at least `MIN_CLAIM_WINDOW = 30 days`; it cannot
shorten or extend existing deadlines. Claims remain open until the epoch is actually swept. Only the Treasury
Safe can take ETH no epoch has reserved (`withdrawUnallocated`); what a posted root owes cannot be touched.

Scoring rules live in `api-server/src/revshare/config.ts`; every epoch records their `configHash`.
Changing them is a product decision: update the site copy and announce it before the epoch it applies to.

The pool's `EpochPosted` event and `getEpoch` return value include `sweepableAt`. Use the matching indexer
schema/event ABI and reindex the revised pool from its deployment block. The API exposes the stored deadline
on epoch and wallet-claim records; `claimWindowSeconds` describes future posts only. This source change requires
a revised pool deployment and does not modify any previously deployed pool.

## Rollback

Before step 6 nothing user-facing changed: unpause V1 (`RESUME_V1_CANVAS=true`) and leave the V2
contracts idle. After step 6, `setRendererContract(rendererV5)` (from the Admin Safe once step 10 is
done) restores the old art, but any V2 burns or trades already made live in storage V2; do not
unpause V1 once the migration is finalized.

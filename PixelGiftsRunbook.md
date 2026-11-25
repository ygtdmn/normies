# Pixel gifts runbook

## What this is

`NormiesPixelGifts` lets a wallet the Admin Safe picks give away #PIXEL from its own wallet balance, with no listing
on the Pixel Market, no price and no fee. A gift can land in three places:

| Call | Where the pixels go |
| --- | --- |
| `giftToWallet(to, amount)` | Wallet `to`'s pixel balance |
| `giftToNormie(id, amount)` | Normie `id`'s canvas balance (its attached pixels), whoever holds it |
| `giftToArena(id, amount)` | Normie `id`'s Arena balance, whoever holds it |

Each has a batch version (`giftToWalletBatch`, `giftToNormieBatch`, `giftToArenaBatch`) for up to 100 entries.

Nothing deployed changes. The pixel ledger, the canvas, the market and the Arena contracts stay as they are. The new
contract gets two existing permissions and hands one new role to the wallet.

This is a deliberate exception to "wallets move #PIXEL to each other only through the market". Gifts skip the market
fee and the price floor, so the revenue pool earns nothing on them. They reach only the gifter wallet's own balance.

## Rules the contract enforces

| Rule | How |
| --- | --- |
| Only the picked wallet can give | `GIFTER_ROLE` (value 32), granted by the owner. The owner itself cannot give without the role. |
| Only its own pixels | No function takes a `from`. Allowances are never used. |
| Cooldowns still apply | The gifter can only give pixels past their cooldown. A wallet gift cools down for one minute in the receiver's wallet, like bought pixels. |
| Wallet gifts: no ledger movers | A receiver holding a ledger mover role (market, canvas, Arena storage, queue, skins, this contract) is refused, and so are the zero address and the gifter itself. Other contracts (revenue pool, splitter, `NormiesArena`) are NOT refused, so check the address. |
| Normie gifts belong to the Normie | Canvas: the holder paints with them or takes them out with `canvas.withdrawPixels`. Arena: the holder takes them out with `store.withdraw`. The gifter cannot take either back. |
| Burned Normies refused | Reverts `Burned` for a burned or never minted id, and for a Normie on `0x…dEaD`. Ids of 10,000 or more revert `InvalidInput`. |
| Arena gifts never register a Normie | A Normie that has not joined keeps the pixels as a frozen balance. Its holder can withdraw them, or join and play with them. |
| Arena gifts skip the agent link check | Same as a round's credits. A registered Normie that sat out for lack of funds plays again from the next round its balance covers. A gift during an open round does not put the Normie in that round. |
| Batches | Up to 100 entries. One bad entry reverts the whole batch. The same Normie may appear twice. |
| Off switches | Owner or GUARDIAN: `setPaused(true)`. Owner: `revokeRoles(wallet, 32)`. |

A canvas gift is the same ledger move as a holder's deposit: the Normie's pixel budget goes up. It never changes the
art, the overlay or the grid size.

## What the contract is trusted with

It holds two strong permissions, so the code is kept small on purpose (about 190 lines, no storage besides the pause
flag and roles).

- **Ledger `ROLE_CANVAS` (1).** Attaching pixels to a Normie is a canvas-role call on the ledger, and the canvas role
  is also the one that can mint and burn pixels. The contract calls only `moveBalance(msg.sender, …)` and
  `attach(msg.sender, …)`, both of which take pixels from the caller's wallet, so supply cannot change through it. A
  bug here would still be serious, which is why the role is listed plainly. If you would rather not grant the canvas
  role, run `wire` and `check` with `LEDGER_ROLE=4`: wallet and Arena gifts work, and `giftToNormie` reverts.
- **Arena storage writer.** May change any Arena record. The contract calls only
  `store.deposit(id, gifter, amount, false)`, right after moving the same amount into the storage, and the storage's
  backing check reverts if the pixels are not there.

## Addresses

| What | Address |
| --- | --- |
| Admin Safe (owns the ledger, the Arena storage and this contract) | `0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa` |
| Pixel ledger `NormiesCanvasStorageV2` | `0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084` |
| `NormiesArenaStorage` | `0x235403069C8516369Eb36d29bb1a498a469Ab9f0` |
| `NormiesCanvasV2` | `0xF14f2852e1fD6A4108156054AF49B3915dc40E2e` |
| `NormiesPixelGifts` (deployed 25 Nov 2026, block 26,495,208, wired the same day) | `0x0309407B7D56a99f32d4Ceb67e21bC1803b5aA8e` |
| Gifter wallet (also the Arena queue's sponsor wallet) | `0x8a8035F056af830B7205c58c1dC037f826fc2B92` |

## Before you start

1. The gifter wallet is `0x8a8035F056af830B7205c58c1dC037f826fc2B92`, the same wallet that sponsors Arena rounds. Anyone
   holding its key can give away its whole pixel balance, so keep in it only what it is meant to give or sponsor.
2. Tests pass:

```bash
forge test --match-path test/NormiesPixelGiftsTest.t.sol
```

## Steps

### 1. Deploy

Any funded EOA. It ends up with nothing: the Safe owns the contract and the deployer's rescue access is locked in the
same script. Until step 3 the contract can reach nothing.

```bash
ARENA_STORAGE=0x235403069C8516369Eb36d29bb1a498a469Ab9f0 PIXEL_GIFTS_ADMIN=0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa forge script script/DeployPixelGifts.s.sol --rpc-url mainnet --broadcast --verify --account <deployer> --sender <deployer address>
```

### 2. Note the addresses

```bash
export GIFTS=0x0309407B7D56a99f32d4Ceb67e21bC1803b5aA8e
```

```bash
export GIFTER=0x8a8035F056af830B7205c58c1dC037f826fc2B92
```

### 3. Build the Safe batch

```bash
script/pixel-gifts-safe.sh wire $GIFTS $GIFTER
```

It refuses unless the contract is tied to the live ledger and Arena storage, owned by the Safe, with the deployer's
rescue access locked. It prints every call and writes `safe-txs/pixel-gifts-wire.json`:

1. ledger `setMoverRoles(GIFTS, 1)`
2. Arena storage `setAuthorizedWriter(GIFTS, true)`
3. gifts `grantRoles(GIFTER, 32)`

Leave the gifter out of the command to wire first and grant later.

### 4. Execute it from the Admin Safe

Transaction Builder, "Import batch". The calls are raw calldata, so compare the targets against what the script
printed and run the Safe's simulation before signing.

### 5. Check

```bash
script/pixel-gifts-safe.sh check $GIFTS $GIFTER
```

Every line must read `ok`, ending in `all good`.

### 6. First gifts

From the gifter wallet, one pixel each way. Once the contract is verified, the Write Contract tab on Etherscan is the
easiest way to call these.

```bash
cast send $GIFTS 'giftToWallet(address,uint256)' <to> 1 --rpc-url mainnet --account <gifter>
```

```bash
cast send $GIFTS 'giftToNormie(uint256,uint256)' <normie id> 1 --rpc-url mainnet --account <gifter>
```

```bash
cast send $GIFTS 'giftToArena(uint256,uint256)' <normie id> 1 --rpc-url mainnet --account <gifter>
```

Read the results:

```bash
cast call 0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084 'balanceOf(address)(uint256)' <to> --rpc-url mainnet
```

```bash
cast call 0x96F2DA32Bb9D429d59ac13dB469f4950cBe02084 'attachedOf(uint256)(uint256)' <normie id> --rpc-url mainnet
```

```bash
cast call 0x235403069C8516369Eb36d29bb1a498a469Ab9f0 'balanceOf(uint256)(uint256)' <normie id> --rpc-url mainnet
```

### 7. After it is live

- Add it to `api-server/src/watch/contracts.ts` so the watcher names it in Discord.

## Reverts the gifter may see

| Error | Meaning |
| --- | --- |
| `Unauthorized` | The caller has no `GIFTER_ROLE`. |
| `Paused` | The contract is paused. |
| `InvalidInput` | Zero amount, zero address, giving to yourself, a receiver that holds a ledger mover role, a Normie id of 10,000 or more, or a bad batch shape. |
| `Burned` | The Normie is burned or was never minted. |
| `InsufficientBalance` | The wallet holds fewer pixels than the amount. |
| `PixelsCoolingDown` | The wallet's pixels arrived less than a minute ago. Wait and retry. |
| `NotAuthorized` | The contract is not wired (or was retired). |

Gas with `--isolate` on the real ledger, full 100 entry batches: `giftToArenaBatch` about 4.5M, `giftToNormieBatch`
about 3.7M.

## What the rest of the system sees

Checked against the indexer (`api-server/indexer/src/arena.ts`, `pixel-market.ts`), the revenue share snapshot and
the Arena app on 25 Nov 2026. Nothing needs a deploy.

- Wallet gift: ledger `BalanceMoved(gifter, to, amount)`, the same event a market fill produces. The indexer adjusts
  both wallet balances.
- Canvas gift: ledger `BalanceMoved(gifter, 0x0, amount)` and `AttachedChanged(id, +amount, newAttached, Deposit)`,
  exactly what a holder's deposit produces. The indexer updates the Normie's pixel count from `AttachedChanged`. The
  canvas's own `PixelsDeposited` event is not emitted, and nothing off-chain reads it.
- Arena gift: ledger `BalanceMoved(gifter, storage, amount)`, storage `Deposited(id, gifter, amount)` and `Leveled`.
  The indexer counts it as a normal deposit with the gifter as the account, so Arena activity shows a deposit from
  that wallet.
- Revenue share starts from the Normie holders at the snapshot block and reads their wallet, attached and Arena
  balances from chain state, so gifted pixels count for whoever holds them then. A wallet with no Normie still
  scores zero.
- The contract's own `GiftedToWallet`, `GiftedToNormie` and `GiftedToArena` events list every gift in one place.
- The 8 Normies per wallet limit on the Arena Enter page is a site rule for joins. A gift does not join a Normie.

## Later

Each command writes a Safe batch to `safe-txs/`.

Give the right to another wallet:

```bash
script/pixel-gifts-safe.sh grant $GIFTS <wallet>
```

Take it back from a wallet:

```bash
script/pixel-gifts-safe.sh revoke $GIFTS <wallet>
```

Retire the contract for good (removes its ledger role and its Arena writer flag):

```bash
script/pixel-gifts-safe.sh retire $GIFTS
```

Fastest stop, from the Safe or a wallet with GUARDIAN on this contract (`grantRoles(wallet, 1)` if you want one):

```bash
cast send $GIFTS 'setPaused(bool)' true --rpc-url mainnet --account <guardian>
```

Gifts already made stay where they are.

## If other contracts are replaced

The contract is tied to one pixel ledger and one `NormiesArenaStorage` for its lifetime. A new canvas, market, queue
or arena logic contract needs nothing here. A new Arena storage needs a new `NormiesPixelGifts`: deploy against it,
wire it, retire this one.

## Rehearsed

On a mainnet fork, 25 Nov 2026: `DeployPixelGifts`, the generated wire batch executed from the impersonated Admin
Safe, `check` all good. Then a wallet gift of 20, a canvas gift of 9 to Normie 1 (attached 1,490 to 1,499) and an
Arena gift of 7 to the same Normie (0 to 7, still registered, storage surplus 0). Total pixel supply was unchanged.
The holder withdrew both gifts through the canvas and the Arena storage. A wallet without the role was refused, and
after the retire batch the old gifter was refused too.

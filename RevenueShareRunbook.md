# Revenue share runbook

How the Normies revenue share runs, what to do every month, and what to do when something goes wrong. Checked
against the code, the deployed contracts and the server on 25 October 2026.

The server itself (access, the vault, rebuilding it) is documented in the private ygtdmn/normies-infra repo. This
runbook only names what it needs from there.

## At a glance

- **Where the money comes from.** Every Pixel Market fill pays the holders' half of its fee straight into the
  revenue pool. Royalties go to the royalty splitter, which sends 50% (`poolBps` 5000) to the pool on `release()`;
  royalties paid in WETH are unwrapped on the way. The other half of both goes to the Admin Safe.
- **Once a month.** On the 1st at 03:00 UTC (plus up to 15 minutes) the server's job builds an epoch covering
  everything since the last one. It scores every wallet from chain data, rebuilds the result on a second RPC, and
  publishes the payout file.
- **You approve it.** The job runs in approval mode: it stops before posting and pages Discord. You check the epoch
  and post it with one command.
- **Claims open 24 hours after the post.** Until then the Operations Safe can cancel it. After that it pays out for
  good. Holders claim at [normies.art/lab/pixel-market](https://normies.art/lab/pixel-market), one transaction for
  every open epoch.
- **Unclaimed funds** return to the pool once an epoch's claim window (365 days from its opening) has passed and
  someone calls `sweep`, so they flow into later epochs.

### Addresses

| What | Address |
| --- | --- |
| Revenue pool (`NormiesRevenuePool`) | `0x481384812e79bf0d11FC0b1704af445D5F06813c` |
| Royalty splitter (`NormiesRoyaltySplitter`) | `0xA68A225f62772E6158f2B5f8afC184AdB69c3282` |
| Admin Safe (3 of 5, hardware wallets) | `0xAF8e9BDcF6463EA1f50f8f70ECF13d85a092a1Aa` |
| Operations Safe (3 of 5, other signers) | `0x94afe25e744aEC9629cB67F63929fA4603898eB7` |
| Revenue share job key (POSTER) | `0xa6d95197D990Afb92675d6F28Cae7982e5935915` |
| Pixel Market | `0x86156A8d6e4B9925F7fEca527ea5D71B0deeDB64` |

### Who can do what

| Who | Holds | On the pool | On the splitter |
| --- | --- | --- | --- |
| Admin Safe | owner of the pool and the splitter | everything below, plus `withdrawUnallocated` (only ETH no epoch has reserved) and role grants | `setPoolBps`, `setTeam`; it is also the team address |
| Operations Safe | GUARDIAN and CONFIG on the pool | `cancelEpoch` (before claims open), `setPaused` (posting only), `setClaimWindow` (at least 30 days, future epochs only) | nothing |
| Job key | POSTER on the pool, gas only | `postEpoch` | nothing (`release` is open to anyone) |
| Anyone | | `claim` / `claimMany` (ETH always goes to the account in the leaf), `sweep` after the deadline, `unwrap` | `release`, `releaseToken` |

Pausing blocks posting only. Claims can never be paused, and nothing can take back what a posted root owes.

## How an epoch is built

`sudo normies revshare run` (the timer runs exactly this) goes in one fixed order and stops at the first thing
that is not right. The rules are in `api-server/src/revshare/guards.ts`.

1. **Where to start.** The pool's `cursorToBlock + 1`, or `REVSHARE_GENESIS_BLOCK` (26,127,870) for the first
   epoch. It refuses to start without `RPC_URL_VERIFY`, or if that is the same endpoint as `RPC_URL`.
2. **Collect.** `splitter.release()` and `pool.unwrap()` when they hold anything. This happens even in approval
   mode; both are permissionless and only move money into the pool.
3. **Where to end.** The chain's finalized block, at least `EPOCH_FINALITY_BLOCKS` (64) below the head, and after
   the release and unwrap. An epoch shorter than `MIN_EPOCH_BLOCKS` (7,000, about 23 hours) is not built.
4. **Build.** Four sample blocks per UTC day, picked from block hashes so nobody can aim for them; every wallet is
   scored at each. The amount is what the pool held unreserved at the end block. The leaves add up to the posted
   `total` (dust stays in the pool). The file goes to `/var/lib/normies-revshare/epochs/<id>.json`.
5. **Rebuild on a second RPC.** Both providers must agree on the end block's hash, then the epoch is built again
   from scratch. Any difference (id, range, amount, total, config, samples, root) stops the run.
6. **Re-check the pool.** Not paused; the epoch id is still `nextEpochId`; the range starts right after the last
   posted one; the total fits what is unreserved now; and the previous epoch's claims are already open. There is
   never more than one epoch a cancel could still reach.
7. **Publish.** The file must be readable at its public URL,
   `https://api.normies.art/revshare/files/<id>.json` (the on-chain `dataURI`), before anything is posted. The job
   reads it back for up to 90 seconds.
8. **Wait for approval.** In approval mode (`REVSHARE_REQUIRE_APPROVAL=true`, the setting today) the job writes
   `/var/lib/normies-revshare/pending/<id>.json` and exits with code 2, which pages Discord. Without approval mode
   it posts here and reads the posted epoch back.

Running the job twice is harmless: a second run finds nothing new to post, or reminds about the epoch already
waiting.

**How the file reaches the public.** The job writes it on the indexer server. nginx serves that folder at
`indexer.normies.art/revshare-epochs/`, behind the same Cloudflare rule as the indexer (requests need the
indexer's secret). The API on Railway fetches it with the secret and republishes it at
`api.normies.art/revshare/files/<id>.json`. The API keeps a found file for 10 minutes and a missing one for 1
minute.

### Scoring

The rules are `api-server/src/revshare/config.ts` (version 4). Every posted epoch records their `configHash` on
chain.

- score = (Normie points + pixel points) × (100 + boost %)
- **Normie points** = Normies held × the bracket multiplier × 10: 1 Normie ×1.00, 2 ×1.15, 5 ×1.30, 10 ×1.45,
  25 ×1.60, 50 or more ×1.75.
- **Pixel points** = pixels × 200. A pixel counts the same on a Normie, in the wallet or escrowed in a listing.
- **Boost** from pixels held: 15 pixels +15%, 100 +35%, 500 +60%, 1,500 +100%.
- **A wallet with no Normie scores zero,** whatever pixels it holds. The protocol's own contracts, the zero address
  and `0x…dEaD` never earn.

## Every month

### The week before the 1st

- [ ] `sudo normies status` shows the next run (`Next normies-revshare.service: … 03:0x`) and the daily reminder.
- [ ] The job key has gas: at least 0.03 ETH at `0xa6d9…5915`. It pays for `release`, `unwrap` and `postEpoch`.
      Top it up from any wallet.
- [ ] The pool is not paused, and the previous epoch's claims are open
      ([api.normies.art/revshare/epochs](https://api.normies.art/revshare/epochs)).
- [ ] Discord reaches your phone: the alert channels notify on all messages. (`DISCORD_MENTION` adds a ping on
      top, only needed if a channel is shared with people who mute it.)
- [ ] Nothing else is scheduled on the server from the 31st to the 2nd. The monthly reboot window is the 15th.
- Optional: `sudo normies revshare run --dry-run` builds the epoch without sending anything. It skips `release` and
  `unwrap`, so its amount can be slightly lower than the real run's.

### The 1st: the run

Between 03:00 and 03:15 UTC the job starts. A month of chain data takes a while (it may run up to 4 hours). When it
stops, Discord shows one of:

| Discord says | Meaning | Do |
| --- | --- | --- |
| **Revenue share: your action is needed on the server.** | An epoch is built, verified, public and waiting (exit code 2). The log lines show its block range, payout count, ETH total, root, file URL and the approve and reject commands. | Review and approve it (below). |
| **Revenue share job finished. Check below whether it posted an epoch.** | Exit code 0. With approval mode this means nothing to post: the pool held nothing unreserved, the epoch would be shorter than 7,000 blocks, or the previous epoch is not open yet. The lines say which. | Usually nothing. |
| **Revenue share job FAILED (exit code N). Nothing was posted after the failing step.** | A check failed or an RPC call broke. | See "When the job fails". |

The daily reminder pages again at 12:00 UTC for as long as an epoch waits.

### Review and approve

Log in to the server (normies-infra has the details), then:

1. `sudo normies revshare pending` shows what is waiting: id, block range, payouts, total ETH, root and file URL.
2. Open the file URL in a browser. It must load: that file is what every holder's claim proof comes from.
3. Check it on an RPC of your own, not the job's. From any checkout of this repo, in `api-server` (with
   `CHAIN_ID=1` and the contract addresses from `deploy/revshare/revshare.env.example`):

   ```bash
   RPC_URL=<your archive RPC> pnpm revshare verify https://api.normies.art/revshare/files/<id>.json
   ```

   It must print `epoch <id> verified` and `epoch <id> is postable now`. Anyone can run this; every holder who wants
   to can check the same file. On the server, `sudo normies revshare verify <url>` does the same through the job's
   RPC.
4. Sanity: the total is close to the pool's unreserved balance
   ([api.normies.art/revshare/status](https://api.normies.art/revshare/status)); the payout count is in line with
   the number of holders; the largest payouts go to the largest holders.
5. Post it:

   ```bash
   sudo normies revshare approve <id>
   ```

   It refuses if the file changed since it was built, re-checks the pool and the public file, posts, reads the
   epoch back and prints when claims open. The watcher then pages `EpochPosted` on Discord: expected, it was you.

To drop it instead: `sudo normies revshare reject <id>`. The file is withdrawn and the next run builds the range
again. Wait 10 minutes before starting that run (`sudo systemctl start normies-revshare.service`): the API may still
serve the rejected file, and the run would fail its public-file check.

### The next 24 hours

The epoch is posted but not open. If anything turns out wrong, the Operations Safe cancels it (see "A wrong epoch,
before claims open"). Otherwise nothing to do.

### Claims open

24 hours after the post, holders can claim at
[normies.art/lab/pixel-market](https://normies.art/lab/pixel-market) (or anyone through `claimMany`). Check the
epoch at `https://api.normies.art/revshare/epochs/<id>`; what a wallet can claim is at
`https://api.normies.art/revshare/wallet/<address>`.

Next month's run posts only after this epoch has opened, which a month later it always has.

## When the job fails

The FAILED message carries the run's last log lines; the full log is `sudo normies logs revshare 200`. Never paste
raw RPC error text anywhere public: it contains the RPC URL, and the URL contains the API key.

A failed run leaves at most an epoch file behind and can simply run again: `sudo systemctl start
normies-revshare.service`. If the server was down on the 1st, the timer runs the missed epoch at the next boot.

| Error | Cause | Do |
| --- | --- | --- |
| HTTP errors, timeouts, rate limits | An RPC provider is down or throttling. | Run again later. If it keeps failing, rotate the key (`scripts/rotate-alchemy-key` in normies-infra for `RPC_URL`; edit `RPC_URL_VERIFY` in the vault for the second provider). |
| `RPC_URL_VERIFY is not set` / `is the same endpoint as RPC_URL` | The settings are wrong. | Fix `revshare.env` in the vault, apply `--tags api`. |
| `the two RPCs disagree on block N` | One provider is behind or on a fork. | Run again later. If it persists, replace the second provider. |
| `the second RPC built a different epoch; not posting` | A provider returned different historical state. | Do not post. Run again later; to find the bad provider, verify the file on a third RPC. |
| `epoch N cannot be posted: the pool is paused` | Posting is paused. | Unpause (Operations Safe) only if the pause was not for an incident. |
| `… has not opened for claims yet` | The previous epoch is still in its 24 hours. | Run after it opens. |
| `… is not the pool's next id` / `… starts at block … but the last posted epoch ended at …` | Something was posted or cancelled since the build. | Find out what (Discord, Etherscan). If it was not you, see "A post nobody expected". |
| `… but the pool has only N wei unreserved now` | ETH left the pool since the build (`withdrawUnallocated`?). | Find out why, then run again. |
| `… does not serve epoch N` | The file is not public. | Check each hop: the file in `/var/lib/normies-revshare/epochs/`, nginx (`sudo normies status`), the API (`api.normies.art/revshare/status`). Then run again. |
| `release() reverted` / `unwrap() reverted` / `postEpoch reverted`, or out of gas | Usually no gas on the job key. | Fund `0xa6d9…5915`, run again. |
| `ACTION NEEDED: … lacks the POSTER role, so … was written as a Safe proposal` | The job key does not hold POSTER. | Treat as an incident unless you rotated the key on purpose. Either the Admin Safe grants POSTER to the job key (`grantRoles(<key>, 4)`) and you run again, or it executes the proposal file in `/var/lib/normies-revshare/proposals/` from its Transaction Builder after signers verify the file. |
| `approve`: `the epoch file changed since it was built` | The file on disk differs from what was approved. | `reject` it, wait 10 minutes, run again. |
| `… was posted (…) but the pool recorded something else` | The post did not record what was built. | Cancel it within 24 hours (below), then investigate. |

## Posting by hand

When the job cannot post (a broken server, or a post that has to go through a Safe), the same order by hand, from a
checkout of this repo in `api-server` with the job's settings in env:

1. `splitter.release()` and `pool.unwrap()` (anyone; the admin panel's Revenue section has both). Wait until both
   blocks are finalized.
2. Build, with the id and range the pool expects next:

   ```bash
   pnpm revshare build --epoch <pool.nextEpochId()> --from <pool.cursorToBlock() + 1> --to <a finalized block>
   ```

   The first epoch starts at `REVSHARE_GENESIS_BLOCK`. `--epoch` is required: the leaves embed it, and an id that
   moved before the post would make every leaf unclaimable.
3. Verify on a second, independent RPC: `RPC_URL=<second provider> pnpm revshare verify <file>`. It must print both
   `verified` and `is postable now`. For a Safe post, every signer runs it on their own RPC before signing.
4. Make the file public: copy it to `/var/lib/normies-revshare/epochs/<id>.json` on the server (owned by
   `normies-revshare`) and open `https://api.normies.art/revshare/files/<id>.json`.
5. Post the `postEpoch(...)` call that `build` printed: from the job key, or from the Admin Safe's Transaction
   Builder.
6. `pnpm revshare verify <file>` once more: for a posted epoch it checks the pool recorded exactly the file.

## Incidents

### A post nobody expected (stolen POSTER key)

Any `EpochPosted` you did not approve means someone else holds the job key. A cancel alone does not stop them: the
cancelled range comes back, and the key can post it again in the next block. The 24 hours before claims open are
the whole defence.

1. **Operations Safe, at once:** one batch with `pool.cancelEpoch(<id>)` and `pool.setPaused(true)`. In the admin
   panel ([normies.art/lab/admin#operations](https://normies.art/lab/admin#operations)) add both to the Safe batch
   and load the file in the Safe app's Transaction Builder; three signers must sign within the 24 hours. Pausing
   stops posting; open epochs keep paying.
2. **Admin Safe:** `pool.revokeRoles(<old key>, 4)`.
3. **New key:** a fresh gas-only EOA. Put its private key in the vault's `revshare.env` (normies-infra), fund it,
   and apply `ansible-playbook site.yml --tags api`. Then the Admin Safe grants it POSTER: `pool.grantRoles(<new
   key>, 4)`. Update the job key address in this runbook.
4. **Operations Safe:** `pool.setPaused(false)`.
5. Run the job (`sudo systemctl start normies-revshare.service`): it builds the cancelled range again under a new
   id, and you approve it as usual.

At least three Operations signers must be able to sign within a day, weekends included.

### A wrong epoch, before claims open

The Operations Safe sends `pool.cancelEpoch(<id>)` (admin panel, Operations or Revenue section, through the Safe
batch). The reservation returns to the pool; if it was the latest epoch, its range opens again. Fix the cause, then
run the job: it posts the range again under a new id.

### After claims opened

A posted epoch cannot be cancelled once its claims open, and claimed ETH cannot be taken back. A root can never pay
out more than its epoch reserved. A mistake can only be made up for in later epochs, by a decision of the team.

### The server is lost

The server has no backups by design: everything is rebuilt. normies-infra rebuilds the server from scratch. Then
restore the file of every posted epoch, because holders' proofs come from those files. For each posted epoch
(`https://api.normies.art/revshare/epochs`, or `getEpoch(id)` on the pool):

```bash
sudo normies revshare build --epoch <id> --from <fromBlock> --to <toBlock>
sudo normies revshare verify /var/lib/normies-revshare/epochs/<id>.json
```

`verify` must print `matches what the pool recorded`. The build is deterministic: same range, same samples, same
scores. Use the scoring rules whose `configHash` the epoch recorded; if `config.ts` changed since, build from the
commit that matches. An epoch that was waiting for approval is simply built again by the next run.

## Changing things

| Change | How | Notes |
| --- | --- | --- |
| Scoring rules | Edit `api-server/src/revshare/config.ts`, merge to main. The server's checkout moves forward within a minute (never during a run) and Railway redeploys the API. | A product decision: update the site copy and announce it before the epoch it applies to. The new `configHash` is recorded with every epoch. |
| Approval mode off | `REVSHARE_REQUIRE_APPROVAL=false` in the vault's `revshare.env`, apply `--tags api`. | The job then posts by itself; the watcher still pages every `EpochPosted`. |
| Discord pings | `DISCORD_MENTION` in `revshare-alert.env` (the job's alerts) and `watcher.env` (on-chain alerts), apply `--tags api`. | `<@your user id>`. Optional: not set today, since the alert channels notify on all messages. |
| RPC keys | `scripts/rotate-alchemy-key` in normies-infra swaps the Alchemy key everywhere; `RPC_URL_VERIFY` is edited in the vault. | The verifier must stay an independent provider. |
| Claim window | Operations Safe, `setClaimWindow(<seconds>)`. | At least 30 days; future epochs only. |
| Holders' share of royalties | Admin Safe, `splitter.setPoolBps(<bps>)`. | `release()` first, so past royalties are split at the old rate. |
| Taking out ETH no epoch owes | Admin Safe, `pool.withdrawUnallocated(<to>, <wei>)`. | Not in the days before the 1st: the epoch is built from what is unreserved. |
| Royalties in another token | `splitter.releaseToken(<token>)` sends it all to the team. | The team converts the holders' share (`poolBps`) to ETH and sends it to the pool address. |

### Sweeping

When an epoch's `sweepableAt` has passed (its claim window, 365 days from its opening for every epoch so far),
anyone can call `pool.sweep(<id>)` (the admin panel's Revenue section has the button). What was not claimed returns
to the pool and flows into later epochs. Until someone sweeps, claims still work.

## Monitoring

- **The job's own alerts** (`revshare-alert.env`): every monthly run ends in a message, and the reminder pages while
  an epoch waits. Exit code 2 is "action needed", anything else non-zero is a failure.
- **The on-chain watcher**: `EpochPosted`, `EpochCancelled`, `Withdrawn`, `RolesUpdated`, `PoolBpsSet`,
  `TeamSet` and ownership changes are urgent; `PausedSet` and `ClaimWindowSet` are notices. Every Admin Safe
  transaction is urgent, every Operations Safe transaction a notice.
- **server-watch** alerts when the revenue share timers stop.
- **The status page and the API**: `api.normies.art/revshare/status` shows the pool's balance, what is reserved,
  what is unreserved, and how much came from market fees and royalties.

## Reference

### On the server

| Command | Does |
| --- | --- |
| `sudo normies revshare pending` | What is waiting for approval. |
| `sudo normies revshare approve <id>` | Post a waiting epoch. |
| `sudo normies revshare reject <id>` | Drop it; the next run builds it again. |
| `sudo normies revshare run --dry-run` | Build without sending anything. |
| `sudo normies revshare verify <file or URL>` | Rebuild a file from chain and check it against the pool. |
| `sudo normies revshare build --epoch <id> --from <block> --to <block>` | Build one epoch by hand. |
| `sudo systemctl start normies-revshare.service` | Run the monthly job now. |
| `sudo normies status` | Next runs, and every app's state. |
| `sudo normies logs revshare [n \| -f]` | The job's and the reminder's log. |

| Path | What |
| --- | --- |
| `/var/lib/normies-revshare/epochs/<id>.json` | Epoch files (public through the API) |
| `/var/lib/normies-revshare/pending/<id>.json` | Epochs waiting for approval |
| `/var/lib/normies-revshare/proposals/<id>.safe.json` | Safe proposals (only when the key lacks POSTER) |
| `/etc/normies/revshare.env`, `/etc/normies/revshare-alert.env` | Settings and keys, root-only, from normies-infra's vault |

Units: `normies-revshare.service` and `.timer` (1st, 03:00 UTC), `normies-revshare-reminder.service` and `.timer`
(daily, 12:00 UTC), `normies-revshare-alert@.service` (runs `deploy/revshare/alert.sh`). They run as the
`normies-revshare` and `normies-alert` accounts.

### Settings (`revshare.env`)

| Setting | Value | Meaning |
| --- | --- | --- |
| `RPC_URL` | an archive node | Reads history and sends the job's transactions. |
| `RPC_URL_VERIFY` | an independent archive provider | The second build. Required. |
| `PRIVATE_KEY` | the job key | POSTER on the pool, gas only. |
| `REVSHARE_REQUIRE_APPROVAL` | `true` | Wait for `approve` before posting. |
| `REVSHARE_PUBLIC_URL` | `https://api.normies.art/revshare/files` | `<url>/<id>.json` is the `dataURI`. |
| `REVSHARE_DIR` | `/var/lib/normies-revshare` | Where files go. |
| `REVSHARE_GENESIS_BLOCK` | `26127870` | The first epoch's first block. |
| `EPOCH_FINALITY_BLOCKS` | `64` | The least distance from the head. |
| `MIN_EPOCH_BLOCKS` | `7000` | The shortest epoch that is posted. |
| `CHAIN_ID` and the contract addresses | mainnet | See `deploy/revshare/revshare.env.example`. |

`revshare-alert.env` holds `DISCORD_WEBHOOK_URL` and `DISCORD_MENTION`, kept apart from the key.

### Public endpoints

| Endpoint | Gives |
| --- | --- |
| `api.normies.art/revshare/status` | The pool's balance, reserved and unreserved ETH, and where it came from |
| `api.normies.art/revshare/epochs`, `/epochs/<id>` | Posted epochs and their state |
| `api.normies.art/revshare/files/<id>.json` | An epoch's full payout file (its `dataURI`) |
| `api.normies.art/revshare/epochs/<id>/proof/<address>` | One wallet's proof |
| `api.normies.art/revshare/wallet/<address>` | A wallet's live standing, what it can claim now (with proofs) and what it has claimed |
| `api.normies.art/revshare/config`, `/tiers` | The scoring rules |

### The code

`api-server/src/revshare/`: `cli.ts` (the commands), `guards.ts` (when not to post), `build.ts`, `sample.ts`,
`score.ts`, `snapshot.ts`, `merkle.ts` (the epoch), `config.ts` (the rules), `publish.ts` (the public-file check),
`proposal.ts` (Safe proposals). The contracts are `src/NormiesRevenuePool.sol` and
`src/NormiesRoyaltySplitter.sol`.

# Revenue share on a schedule

`pnpm revshare run` is the whole monthly job. A timer runs it on the first of each month at 03:00 UTC on the server
that hosts the indexer, which also serves the epoch files publicly (see On the server).

A posted root opens for claims 24 hours later (`POST_DELAY`) and pays out for good from then on; until then only the
Operations Safe can cancel it. So a run always goes in this order and stops at the first problem (the rules are in `api-server/src/revshare/guards.ts`):

1. Reads the pool: the next epoch starts where the last one ended (`REVSHARE_GENESIS_BLOCK` the first time).
   Refuses to start at all without `RPC_URL_VERIFY`, or if it is the same endpoint as `RPC_URL`.
2. Calls `release()` on the royalty splitter and `unwrap()` on the pool when they hold anything.
3. Ends the epoch at the chain's finalized block (and at least `EPOCH_FINALITY_BLOCKS` deep), after those two
   transfers.
4. Builds the epoch: four sampled blocks per UTC day, every wallet scored at each, payouts and Merkle proofs
   written to `REVSHARE_DIR/epochs/<id>.json`.
5. Rebuilds it from scratch against `RPC_URL_VERIFY`, after checking both providers agree on the end block's
   hash. Any difference (amount, samples, total, root, ...) means it does not post.
6. Re-reads the pool: not paused, same next epoch id, contiguous range, enough unreserved ETH, and the previous
   epoch already open for claims (a cancel only hands back the latest range, so there is never more than one
   epoch a cancel could still reach; an early run stops before building).
7. Checks the epoch file is public at `REVSHARE_PUBLIC_URL/<id>.json` (the API; that URL is the `dataURI`), then posts the
   root and reads the posted epoch back. There is no owner key on this machine: the job's
   `PRIVATE_KEY` holds the pool's POSTER role and nothing else. Claims open 24 hours later (`POST_DELAY`); until
   then the Operations Safe can `cancelEpoch` a bad root, and the next run posts the range again under a new id.
   A key without the role writes `REVSHARE_DIR/proposals/<id>.safe.json` (a Safe Transaction Builder batch for the
   pool owner) instead, and later runs leave a pending proposal alone until the pool shows it posted.

An epoch shorter than `MIN_EPOCH_BLOCKS` is not posted, so running the job twice is harmless. A run that fails
leaves nothing behind but the epoch file and can simply be run again.

## On the server

The server is set up by **ygtdmn/normies-infra** (Ansible), not from this folder:
- the job's own account (`normies-revshare`), the units and the timers;
- `/etc/normies/revshare.env` and `/etc/normies/revshare-alert.env`, from its vault. The `.env.example` files here
  document the settings.

Only `alert.sh` here runs on the server: the alert unit runs it from the server's checkout of this repo.

- **Epoch files** go to `/var/lib/normies-revshare/epochs`.
  - nginx serves that folder on the indexer host at `/revshare-epochs/`, behind the same Cloudflare rule as the
    indexer.
  - The API, which already holds the indexer secret, serves each file publicly at
    `https://api.normies.art/revshare/files/<id>.json`. That URL is the epoch's on-chain `dataURI` and the site reads
    proofs through it.
  - A run checks that URL serves the new file before it posts.
- **Updating the job:** merge to `main`. A change under `api-server/` or `deploy/revshare/` deploys itself within a
  minute, never while a run is going.

## Approval mode

With `REVSHARE_REQUIRE_APPROVAL=true` (the launch setting) nothing is posted without a person. The monthly run does
every step up to the post: it builds the epoch, rebuilds it on the second RPC, re-checks the pool and makes the file
public at `https://api.normies.art/revshare/files/<id>.json`. Then it stops, writes
`/var/lib/normies-revshare/pending/<id>.json` and pages Discord. Until someone acts, the daily reminder
(`normies-revshare-reminder.timer`, 12:00 UTC) pages again every day, and a later monthly run only reminds instead
of building another epoch.

```bash
sudo normies revshare pending          # what is waiting, with its totals and the file URL
sudo normies revshare verify https://api.normies.art/revshare/files/<id>.json
sudo normies revshare approve <id>     # re-checks the pool and the public file, then posts
sudo normies revshare reject <id>      # drops it; the next run builds the range again
```

`approve` refuses if the epoch file changed since it was built, if the pool moved on, or if the public file is not
the same. After it posts, claims open 24 hours later and the Operations Safe can still cancel. Set
`REVSHARE_REQUIRE_APPROVAL=false` once the job has earned it.

## Alerts

Every run of the job, and every reminder that finds something waiting, ends in a Discord message through
`normies-revshare-alert@.service` (webhook and an optional mention in `/etc/normies/revshare-alert.env`, kept apart
from the poster key). Exit code 2 is "your action is needed": an epoch waits for approval, or a Safe proposal was
written because the key lacks POSTER. Any other non-zero exit is a failure. A finished run posts its last lines, so
an epoch it posted shows up there. Separately, page on every `EpochPosted` that this channel does not show: that is
the stolen key case in the runbook ("A post nobody expected").

## Operate

```bash
sudo normies status                              # the next run, among everything else
sudo systemctl start normies-revshare.service    # run one now
sudo normies logs revshare 200                   # what the last runs did
sudo normies revshare run --dry-run
```

A dry run does everything except send transactions: it reports the block range, the payout count and the root it
would post. A dry run without `RPC_URL_VERIFY` skips the second rebuild and says so; a real run never does.
`pnpm revshare verify <file or URL>` rebuilds an epoch from any archive node and checks it against the pool: a posted
epoch must match what the pool recorded, an unposted one must be postable now. Anyone can run it on the public URL.

## Changing the rules

Scoring lives in `api-server/src/revshare/config.ts`; every epoch file records its `configHash` and the pool
stores it with the root. Change the config, deploy the API (its live projection uses the same file), announce it,
and the next run applies it.

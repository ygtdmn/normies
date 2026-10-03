# Revenue share on a schedule

`pnpm revshare run` is the whole monthly job; the timer here runs it on the first of each month at 03:00 UTC on
the server that hosts the API (the epoch file has to land in the directory the API serves).

A posted root pays out at once and can never be cancelled, so a run always goes in this order and stops at the
first problem (the rules are in `api-server/src/revshare/guards.ts`):

1. Reads the pool: the next epoch starts where the last one ended (`REVSHARE_GENESIS_BLOCK` the first time).
   Refuses to start at all without `RPC_URL_VERIFY`, or if it is the same endpoint as `RPC_URL`.
2. Calls `release()` on the royalty splitter and `unwrap()` on the pool when they hold anything.
3. Ends the epoch at the chain's finalized block (and at least `EPOCH_FINALITY_BLOCKS` deep), after those two
   transfers.
4. Builds the epoch: four sampled blocks per UTC day, every wallet scored at each, payouts and Merkle proofs
   written to `REVSHARE_DIR/epochs/<id>.json`.
5. Rebuilds it from scratch against `RPC_URL_VERIFY`, after checking both providers agree on the end block's
   hash. Any difference (amount, samples, total, root, ...) means it does not post.
6. Re-reads the pool: not paused, same next epoch id, contiguous range, enough unreserved ETH.
7. Posts the root from the owner key and reads the posted epoch back. Claims open in that block. There is no
   dispute window, which is why steps 5 and 6 exist.

An epoch shorter than `MIN_EPOCH_BLOCKS` is not posted, so running the job twice is harmless. A run that fails
leaves nothing behind but the epoch file and can simply be run again.

## Install

```bash
# as root, once
useradd --system --home /opt/normies --shell /usr/sbin/nologin normies   # skip if the API already runs as it
mkdir -p /etc/normies && cp revshare.env.example /etc/normies/revshare.env && chmod 600 /etc/normies/revshare.env
$EDITOR /etc/normies/revshare.env                                          # fill every value
cp normies-revshare.service normies-revshare.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now normies-revshare.timer
```

The service expects the repo at `/opt/normies/smart-contracts` with `pnpm install` done in `api-server`, `pnpm`
at `/usr/bin/pnpm` (adjust `ExecStart` otherwise), and `REVSHARE_DIR` writable by the `normies` user and equal to
the API's own `REVSHARE_DIR`.

## Operate

```bash
systemctl list-timers normies-revshare.timer        # next run
systemctl start normies-revshare.service            # run one now
journalctl -u normies-revshare.service -n 200       # what the last run did
sudo -u normies -i sh -c 'cd /opt/normies/smart-contracts/api-server && set -a && . /etc/normies/revshare.env && pnpm revshare run --dry-run'
```

A dry run does everything except send transactions: it reports the block range, the payout count and the root it
would post. A dry run without `RPC_URL_VERIFY` skips the second rebuild and says so; a real run never does.
`pnpm revshare verify data/revshare/epochs/<id>.json` rebuilds an epoch file from any archive node and checks it
against the pool: a posted epoch must match what the pool recorded, an unposted one must be postable now.

## Changing the rules

Scoring lives in `api-server/src/revshare/config.ts`; every epoch file records its `configHash` and the pool
stores it with the root. Change the config, deploy the API (its live projection uses the same file), announce it,
and the next run applies it.

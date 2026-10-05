# On-chain watcher

`normies-watcher.service` runs `api-server/src/watch/cli.ts` on the indexer host. Every 30 seconds it reads the
new blocks (3 behind the head) and posts to Discord, one message per transaction:

- **every transaction either Safe executes**, decoded call by call (MultiSend batches unpacked) with the signer who
  sent it. Admin Safe transactions are urgent, Operations Safe transactions are notices;
- **Safe signer and setup changes** (owners, threshold, modules, guards): urgent;
- **ownership, roles, movers, writers, cooldowns, fee recipients, royalty routes, withdrawals** on the 20 Normies
  contracts: urgent;
- **`EpochPosted` and `EpochCancelled`**: urgent. In approval mode the only `EpochPosted` you should ever see is
  right after you ran `revshare.sh approve`; any other is the stolen poster key case (runbook, "A post nobody
  expected");
- operating changes (pauses, prices, burn tiers, claim window, Legendary Canvas): notices.

Urgent messages start with `DISCORD_MENTION`, so set it to your user id and enable Discord notifications on your
phone. The watcher also says when it starts, when it has failed for 10 minutes ("blind"), when it recovers, and when
it crashes; systemd restarts it after a minute, and it resumes from the last finished block
(`/var/lib/normies-watcher/state.json`), so nothing is skipped.

```bash
# as root, once (the repo is already at /opt/normies for the revenue share job)
cp /opt/normies/deploy/watcher/watcher.env.example /etc/normies/watcher.env && chmod 600 /etc/normies/watcher.env
$EDITOR /etc/normies/watcher.env
cp /opt/normies/deploy/watcher/normies-watcher.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now normies-watcher.service
journalctl -u normies-watcher -f
```

To see what it would have said for a past range, without posting:
`cd /opt/normies/api-server && RPC_URL=... node_modules/.bin/tsx src/watch/cli.ts replay <from> <to>`.

Contract addresses and the watched events are in `api-server/src/watch/contracts.ts`; `abi.json` next to it holds the
write functions and events of every Normies contract and the Safe, generated from `out/`.

# On-chain watcher

`normies-watcher.service` runs `api-server/src/watch/cli.ts` on the indexer host. Every 30 seconds it reads the
new blocks (3 behind the head) and posts to Discord, one message per transaction:

- **every transaction either Safe executes**, decoded call by call (MultiSend batches unpacked) with the signer who
  sent it. Admin Safe transactions are urgent, Operations Safe transactions are notices;
- **Safe signer and setup changes** (owners, threshold, modules, guards): urgent;
- **ownership, roles, movers, writers, cooldowns, fee recipients, royalty routes, withdrawals** on the 20 Normies
  contracts: urgent;
- **`EpochPosted` and `EpochCancelled`**: urgent. In approval mode the only `EpochPosted` you should ever see is
  right after you ran `sudo normies revshare approve`; any other is the stolen poster key case
  ([revenue share runbook, "A post nobody expected"](../../RevenueShareRunbook.md#a-post-nobody-expected-stolen-poster-key));
- operating changes (pauses, prices, burn tiers, claim window, Legendary Canvas): notices.

Urgent messages start with `DISCORD_MENTION`, so set it to your user id and enable Discord notifications on your
phone. The watcher also says when it starts, when it has failed for 10 minutes ("blind"), when it recovers, and when
it crashes; systemd restarts it after a minute, and it resumes from the last finished block
(`/var/lib/normies-watcher/state.json`), so nothing is skipped.

The server is set up by **ygtdmn/normies-infra** (Ansible), not from this folder:
- the watcher's own account (`normies-watcher`) and its unit;
- `/etc/normies/watcher.env`, from its vault (`watcher.env.example` here documents the settings);
- auto-deploy: a merge to `main` that changes `api-server/` restarts it onto the new code within a minute.

`sudo normies logs watcher` shows its log, and `sudo normies restart watcher` restarts it. It posts that it started,
which is a quick test of its Discord channel.

To see what it would have said for a past range, without posting:
`cd api-server && RPC_URL=... pnpm exec tsx src/watch/cli.ts replay <from> <to>`, from any checkout.

Contract addresses and the watched events are in `api-server/src/watch/contracts.ts`; `abi.json` next to it holds the
write functions and events of every Normies contract and the Safe, generated from `out/`.

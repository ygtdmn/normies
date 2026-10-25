# Revenue share job

The monthly revenue share epoch: how it is built, approving it, alerts, failures, incidents and settings are all in
the runbook, [RevenueShareRunbook.md](../../RevenueShareRunbook.md). The job itself is `api-server/src/revshare`
(`pnpm revshare`, `sudo normies revshare` on the server).

The server is set up by ygtdmn/normies-infra (Ansible): the job's account, its units and timers, nginx, and the
settings from its vault. Of this folder, only `alert.sh` runs there:

- `alert.sh`: the Discord message after every run (`normies-revshare-alert@.service` runs it from the server's
  checkout of this repo).
- `revshare.env.example`, `revshare-alert.env.example`: the settings, documented.

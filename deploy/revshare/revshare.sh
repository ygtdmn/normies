#!/bin/bash
# Runs a revshare command on the server the way the timer does: as the normies user, with /etc/normies/revshare.env.
#   sudo /opt/normies/deploy/revshare/revshare.sh pending          what is waiting for approval
#   sudo /opt/normies/deploy/revshare/revshare.sh approve <id>     post a waiting epoch (re-checks the pool first)
#   sudo /opt/normies/deploy/revshare/revshare.sh reject <id>      drop it; the next run builds the range again
#   sudo /opt/normies/deploy/revshare/revshare.sh run --dry-run    everything except sending transactions
#   sudo /opt/normies/deploy/revshare/revshare.sh verify <file or URL>
set -euo pipefail
if [ "$(id -u)" != 0 ]; then
    echo "run it with sudo (it reads /etc/normies/revshare.env, which only root can read)" >&2
    exit 1
fi
set -a
. /etc/normies/revshare.env
set +a
cd /opt/normies/api-server
exec sudo -E -u normies /opt/normies/api-server/node_modules/.bin/tsx src/revshare/cli.ts "$@"

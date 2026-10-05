#!/bin/bash
# Discord message for the last run of a revshare unit: alert.sh <unit name without .service>
# (OnFailure= / OnSuccess= in normies-revshare.service and normies-revshare-reminder.service).
# Exit code 2 from the job means "action needed": an epoch waits for approval, or a Safe proposal was written.
set -u
unit="${1:-normies-revshare}.service"
status=$(systemctl show -p ExecMainStatus --value "$unit")
logs=$(journalctl -u "$unit" -n 30 --no-pager -o cat _SYSTEMD_INVOCATION_ID="$(systemctl show -p InvocationID --value "$unit")" 2>/dev/null | tail -c 1500)
[ -n "$logs" ] || logs=$(journalctl -u "$unit" -n 30 --no-pager -o cat 2>&1 | tail -c 1500)
case "$status" in
    0)
        # The daily reminder only speaks when something is waiting.
        [ "$unit" = "normies-revshare-reminder.service" ] && exit 0
        title="Revenue share job finished. Check below whether it posted an epoch."
        ;;
    2) title="${DISCORD_MENTION:+$DISCORD_MENTION }Revenue share: your action is needed on the server." ;;
    *) title="${DISCORD_MENTION:+$DISCORD_MENTION }Revenue share job FAILED (exit code $status). Nothing was posted after the failing step." ;;
esac
if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
    echo "$title (DISCORD_WEBHOOK_URL is not set)"
    exit 0
fi
payload=$(python3 -c 'import json, sys; print(json.dumps({"content": sys.argv[1] + "\n```\n" + sys.argv[2][-1700:] + "\n```", "allowed_mentions": {"parse": ["users", "roles", "everyone"]}}))' "$title" "$logs")
curl -fsS -m 20 -H "content-type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null

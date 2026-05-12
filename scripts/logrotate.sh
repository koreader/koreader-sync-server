#!/bin/sh
# Rotates nginx log files daily. Keeps 7 days of history.
# Called via cron inside the container.
LOG_DIR="/app/koreader-sync-server/logs"
ENV="${GIN_ENV:-production}"

for name in access error; do
    log="$LOG_DIR/$ENV-$name.log"
    [ -f "$log" ] || continue
    mv "$log" "$log.1"
done

# Signal nginx to reopen log files
kill -USR1 "$(cat /app/koreader-sync-server/tmp/$ENV-nginx.pid 2>/dev/null)" 2>/dev/null

# remove logs older than 7 days
find "$LOG_DIR" -name "*.log.[0-9]*" -mtime +7 -delete 2>/dev/null
exit 0

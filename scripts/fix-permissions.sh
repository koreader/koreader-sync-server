#!/bin/sh
# Runs at container startup (via /etc/my_init.d/) before services start.
# Ensures mounted volumes are writable by the nginx worker (nobody) and redis.
chmod 777 /app/koreader-sync-server/logs /var/lib/redis /var/log/redis 2>/dev/null

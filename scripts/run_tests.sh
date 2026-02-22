#!/bin/sh
set -e

# Start Redis in the background and wait for it
redis-server --daemonize yes
timeout 10 sh -c 'until redis-cli ping 2>/dev/null | grep -q PONG; do sleep 1; done'

# Run busted from the app directory
cd /app/koreader-sync-server
exec busted "$@"

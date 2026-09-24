#!/bin/bash

HOST=${HEALTH_CHECK_HOST:-google.com}

# Handle SIGTERM
sigterm() {
    echo "Received SIGTERM, exiting..."
    trap - SIGTERM
    kill -- -$$
}
trap sigterm SIGTERM

# Reports what failed and exits unhealthy
fail() {
    echo "$1"
    exit 1
}

# Network check (runs through WireGuard, the only interface in this namespace)
# Ping uses both exit codes 1 and 2. Exit code 2 cannot be used for docker health checks,
# therefore we use this script to catch error code 2

# Check DNS resolution works (each lookup limited to 5 seconds so a dead tunnel still reaches fail())
if ! timeout 5 nslookup -q=a "$HOST" > /dev/null && ! timeout 5 nslookup -q=aaaa "$HOST" > /dev/null
then
    fail "DNS resolution failed"
fi

if ! ping -c 2 -w 10 "$HOST" # Get at least 2 responses and timeout after 10 seconds
then
    fail "Network is down"
fi

echo "Network is up"

# Service check
if ! ip link show wg0 > /dev/null 2>&1; then
    fail "WireGuard interface wg0 not found"
fi

# Process names are truncated to 15 characters, so transmission-daemon shows as transmission-da
if ! pgrep -x transmission-da > /dev/null; then
    fail "transmission-daemon process not running"
fi

echo "WireGuard and transmission-daemon are running"
exit 0

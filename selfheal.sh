#!/bin/bash

# Started by start.sh when SELFHEAL is enabled. Runs healthcheck.sh from the same folder on a schedule
# for as long as the container runs. After SELFHEAL_MAX_FAILURES failed checks in a row, shuts down
# so Docker's restart policy restarts the container. Checks that pass reset the failure count.

MAX_FAILURES=${SELFHEAL_MAX_FAILURES:-3}
[[ "$MAX_FAILURES" =~ ^[1-9][0-9]*$ ]] || MAX_FAILURES=3

INTERVAL=${SELFHEAL_INTERVAL:-60}
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || INTERVAL=60

HEALTHCHECK="$(dirname "$0")/healthcheck.sh"

failures=0
while true; do
    sleep $INTERVAL
    if output=$(timeout 30 "$HEALTHCHECK" 2>&1); then
        failures=0
    else
        failures=$((failures + 1))
        reason=$(tail -1 <<< "$output")
        echo "selfheal: health check failed ($failures of $MAX_FAILURES in a row): ${reason:-timed out}"
        if (( failures >= MAX_FAILURES )); then
            echo "selfheal: restarting container"
            kill -TERM 1
            exit 0
        fi
    fi
done

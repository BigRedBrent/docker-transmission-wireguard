#! /bin/bash

# Exit on error
set -e

if [[ -n "$REVISION" ]]; then
    echo "Image revision: $REVISION"
fi

# Runs the script passed to this function, if it exists and is executable, along with any arguments passed after it.
# Waits for the script to finish before continuing. It's started in the background then waits for it to finish.
# A shutdown signal can still be handled while it is waiting for it to finish running.
run_user_script() {
    local script="/scripts/$1"
    shift
    [[ -x "$script" ]] || return 0
    echo "Executing $script"
    local rc=0
    "$script" "$@" &
    wait $! || rc=$?
    echo "$script returned $rc"
}

run_user_script wireguard-pre-start.sh "$@"

echo "Current public IP is:"
curl --silent -w "\n" ipecho.net/plain

if ip netns ls | grep -q "physical"
then
    # Dangling network from previous run, clean up
    echo "Clean up dangling network namespaces"
    ip -all netns delete
fi

# Grab information from the default interface set up in the container
GW=$(/sbin/ip route list match 0.0.0.0 | awk '{print $3}')
INT=$(/sbin/ip route list match 0.0.0.0 | awk '{print $5}')
INT_IP=$(ip -f inet addr show "$INT" | awk '/inet / {print $2}')
# Broadcast may be absent (e.g. /32). Only pass brd when `ip addr` showed one, we want to mirror the original
INT_BRD=$(ip -f inet addr show "$INT" | awk '/inet / {if ($3 == "brd") print $4}')

echo "Found default container interface, will use this in setup:"
echo "Interface: $INT"
echo "Gateway: $GW"
echo "Interface address: $INT_IP"
echo "Interface broadcast: $INT_BRD"

# Use CONFIG_FILE when it points to an existing file. Otherwise pick a random WireGuard config from /wg-config,
# skipping the one used last time when there's another one to choose from.
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    if [[ -n "$CONFIG_FILE" ]]; then
        echo "CONFIG_FILE $CONFIG_FILE was not found, selecting a random config from /wg-config instead"
    fi
    LAST_CONFIG=$(cat /tmp/last-wg-config 2>/dev/null || true)
    CONFIG_FILE=$(ls /wg-config/*.conf 2>/dev/null | grep -vxF "$LAST_CONFIG" | shuf -n 1 || true)
    if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE=$(ls /wg-config/*.conf 2>/dev/null | shuf -n 1 || true)
    fi
    if [[ -z "$CONFIG_FILE" ]]; then
        echo "ERROR: No WireGuard config found. Set CONFIG_FILE, or add .conf files to /wg-config"
        exit 1
    fi
    echo "$CONFIG_FILE" > /tmp/last-wg-config
    echo "Randomly selected WireGuard config: $CONFIG_FILE"
fi

# Resolve WireGuard Endpoint hostnames to IPs while eth0 is still in this namespace
# (uses dig @WG_BOOTSTRAP_DNS, default 1.1.1.1 — not Docker's 127.0.0.11).
RESOLVED_CONFIG="$(mktemp)"
trap 'rm -f "$RESOLVED_CONFIG"' EXIT
python3 /opt/wireguard/resolve-wg-endpoints.py "$CONFIG_FILE" "$RESOLVED_CONFIG"

# Lets a script inspect or adjust the resolved config before it's used
run_user_script wireguard-post-config.sh "$RESOLVED_CONFIG"

# Override DNS to Cloudflare unless ACCEPT_DNS_PRIVACY_LOSS is set to true (case insensitive).
# If set, Docker's resolver (often 127.0.0.11) may bypass the WireGuard tunnel for DNS.
if [ -z "${ACCEPT_DNS_PRIVACY_LOSS}" ] || ! [[ "${ACCEPT_DNS_PRIVACY_LOSS,,}" == "true" ]]; then
    echo "Overriding DNS to Cloudflare"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
else
    echo "ACCEPT_DNS_PRIVACY_LOSS=true: not overriding /etc/resolv.conf; DNS queries may not use the WireGuard tunnel."
fi

echo "DNS config:"
cat /etc/resolv.conf

# Create a "physical" network namespace and move our eth0 there
ip netns ls
ip netns add physical
ip link set "$INT" netns physical

# Create wireguard interface in physical namespace and move it to the default namespace
ip -n physical link add wg0 type wireguard
ip -n physical link set wg0 netns 1

# Restore IP and route configuration for the default interface, start it
if [ -n "$INT_BRD" ]; then
    ip -n physical addr add "$INT_IP" dev "$INT" brd "$INT_BRD"
else
    ip -n physical addr add "$INT_IP" dev "$INT"
fi
ip -n physical link set "$INT" up
#ip -n physical link set lo up
if ! ip -n physical route add default via "$GW" dev "$INT"; then
    echo "Default route via $GW was not accepted as on-link, retrying with onlink"
    ip -n physical route add default via "$GW" dev "$INT" onlink
fi

#
# Setting up Wireguard
# We need to make the wg0 interface separately to do the namespace linking
# and we can't use wg-quick after that. So the rest is done "manually".
#

# Get the Address from the config file. For now: Only keep the first address (typically the IPv4 address)
address=$(python3 /opt/wireguard/get-config-value.py Address "$RESOLVED_CONFIG" | cut -d, -f1 | xargs)
#dns=$(python3 /opt/wireguard/get-config-value.py DNS "$RESOLVED_CONFIG")

ip addr add "$address" dev wg0

stripped_config_file=$(mktemp)
python3 /opt/wireguard/strip-wg-config.py "$RESOLVED_CONFIG" > "$stripped_config_file"

echo "Will use wg config from $stripped_config_file"
wg setconf wg0 "$stripped_config_file"
ip link set wg0 up
#ip link set lo up
ip route add default dev wg0

#
# Wireguard interface is now set up and should be connected
#
echo "Wireguard is up - new IP:"
curl --silent -w "\n" ipecho.net/plain

run_user_script routes-post-start.sh "$@"

# Arguments for the Transmission scripts, in the same order the OpenVPN image passed its --up arguments:
# device, tun MTU, link MTU, local tunnel address, remote tunnel address (none with WireGuard), script context
WG_MTU=$(cat /sys/class/net/wg0/mtu)
USER_SCRIPT_ARGS=("wg0" "$WG_MTU" "$WG_MTU" "${address%/*}" "" "init")

# Create a veth link pair, one interface in each namespace
ip link add veth1 type veth peer name veth2 netns physical

# Set their IPs, CIDR with only two addresses to limit ip route ranges
ip addr add 10.10.13.36/31 dev veth1
ip -n physical addr add 10.10.13.37/31 dev veth2

# Start the veth interfaces
ip link set veth1 up
ip -n physical link set veth2 up

# Start a reverse proxy in the physical namespace
ip netns exec physical nginx -c /opt/nginx/server.conf

run_user_script transmission-pre-start.sh "${USER_SCRIPT_ARGS[@]}"

# Set TRANSMISSION_WEB_HOME if user has selected an alternative web UI
if [[ -n "$TRANSMISSION_WEB_UI" ]]; then
    case "$TRANSMISSION_WEB_UI" in
        combustion)        ui_dir="combustion-release" ;;
        kettu)             ui_dir="kettu" ;;
        flood-for-transmission) ui_dir="flood-for-transmission" ;;
        shift)             ui_dir="shift" ;;
        transmissionic)    ui_dir="transmissionic" ;;
        transmission-web-control) ui_dir="transmission-web-control" ;;
        *)
            echo "ERROR: Unknown TRANSMISSION_WEB_UI value: $TRANSMISSION_WEB_UI"
            echo "Valid options: combustion, kettu, flood-for-transmission, shift, transmissionic, transmission-web-control"
            exit 1
            ;;
    esac

    export TRANSMISSION_WEB_HOME="/opt/transmission-ui/${ui_dir}"
    echo "Using alternative Transmission UI: $TRANSMISSION_WEB_UI (from $TRANSMISSION_WEB_HOME)"
fi

# Make sure TRANSMISSION_HOME exists and create/update settings.json
mkdir -p "$TRANSMISSION_HOME"
python3 /opt/transmission/updateSettings.py /opt/transmission/default-settings.json ${TRANSMISSION_HOME}/settings.json || exit 1

# Support running Transmission as non-root (and set permissions on folders)
. /opt/transmission/userSetup.sh

# Start Transmission in its own session, so a shutdown signal reaches this script first
# and transmission-pre-stop.sh can run while Transmission and the tunnel are still up
setsid su --preserve-environment ${RUN_AS} -s /bin/bash -c "/usr/bin/transmission-daemon --foreground -g ${TRANSMISSION_HOME}" &
transmission_pid=$!

# Started after Transmission, so that slow startup steps such as applying folder permissions don't count as failures
if [[ "${SELFHEAL,,}" == "true" ]]; then
    /etc/scripts/selfheal.sh &
fi

# Exits with 143, the conventional code for a process stopped by SIGTERM, so a shutdown started
# from inside the container (such as by selfheal.sh) counts as a failure for restart: on-failure.
# Docker never applies restart policies after a manual stop, so this doesn't affect docker stop.
stop_transmission() {
    trap - TERM INT
    run_user_script transmission-pre-stop.sh "${USER_SCRIPT_ARGS[@]}"
    kill -TERM "$transmission_pid" 2>/dev/null || true
    wait "$transmission_pid" || true
    run_user_script transmission-post-stop.sh "${USER_SCRIPT_ARGS[@]}"
    exit 143
}
trap stop_transmission TERM INT

run_user_script transmission-post-start.sh "${USER_SCRIPT_ARGS[@]}"

# If update-port.sh exists, run it in the background to keep Transmission's forwarded port updated
if [[ -x /scripts/update-port.sh ]]; then
    echo "Starting /scripts/update-port.sh in the background"
    /scripts/update-port.sh &
fi

# Stay running until Transmission exits
transmission_status=0
wait "$transmission_pid" || transmission_status=$?
exit "$transmission_status"

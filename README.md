# WireGuard and Transmission with WebUI

This project creates a Docker image that bundles WireGuard and Transmission.
It sets up networking in a way that ensures Transmission traffic is always routed through the VPN.

## Work in progress

This image is under construction. Breaking changes might occur without warning!

If you're already running an instance of `haugene/transmission-openvpn`, _I would not recommend_
swapping your installation for this image just yet. Please test it and report any issues.

## Quick start

The new image differs a bit from the old, and I'll hopefully get to document that better soon.
But from the "getting it to run" perspective, the first things that come to mind are:

* You need to mount a config file
* It requires running in privileged mode

This might change, but this is how it's running now.

I've also changed the Transmission settings handling a bit. The container will still accept
environment variables, but defaults are read from a file. This is to de-clutter the Dockerfile a bit.
There are still a handful of default settings being set as ENV variables in the Dockerfile to
get the PUID/PGID working like it used to. I'll try to clean up that as well.

If you're already running the old image, I'd recommend setting the ports option to: `- 9092:9091`.
That way you'll map it to port 9092 locally and you can have them both running at the same time.


### Example Docker Compose file:
```yaml
services:
  transmission-wireguard:
    # No versioned tags yet, pulling latest build from the main branch.
    image: haugene/transmission-wireguard:main
    container_name: transmission-wireguard
    restart: unless-stopped
    privileged: true
    ports:
      - 9091:9091
    volumes:
      - /your/storage/path/:/data # where transmission will store downloads
      - /your/config/path/:/config # where transmission-home (state) is stored
      - /your/wireguard-configs/:/wg-config # example mount for WireGuard configs
      - /your/scripts/path/:/scripts # optional custom scripts
    environment:
      - PUID=1000
      - PGID=1000

      # Optional settings, uncomment to use:
      #- SELFHEAL=true
      #- MAX_SELFHEAL_FAILURES=3
      #- SELFHEAL_INTERVAL=60
      #- HEALTH_CHECK_HOST=google.com
      #- ENABLE_PORT_CHECK=true # Only works if update-port.sh is added to /scripts
      #- CONFIG_FILE=/wg-config/my_wg.conf # This is not necessary if you place WireGuard .conf files in /wg-config
      #- TRANSMISSION_RPC_ENABLED=true
      #- TRANSMISSION_RPC_PORT=9091
      #- TRANSMISSION_RPC_AUTHENTICATION_REQUIRED=true
      #- TRANSMISSION_RPC_USERNAME=username
      #- TRANSMISSION_RPC_PASSWORD=password
      #- TRANSMISSION_DOWNLOAD_DIR=/data/completed
      #- TRANSMISSION_INCOMPLETE_DIR_ENABLED=true
      #- TRANSMISSION_INCOMPLETE_DIR=/data/incomplete
      #- TRANSMISSION_WATCH_DIR_ENABLED=true
      #- TRANSMISSION_WATCH_DIR=/data/watch
      #- TRANSMISSION_SCRIPT_TORRENT_ADDED_ENABLED=true
      #- TRANSMISSION_SCRIPT_TORRENT_ADDED_FILENAME=
      #- TRANSMISSION_SCRIPT_TORRENT_DONE_ENABLED=true
      #- TRANSMISSION_SCRIPT_TORRENT_DONE_FILENAME=
      #- TRANSMISSION_SCRIPT_TORRENT_DONE_SEEDING_ENABLED=true
      #- TRANSMISSION_SCRIPT_TORRENT_DONE_SEEDING_FILENAME=
    logging:
      driver: json-file
      options:
        max-size: 10m
```

## WireGuard config

Mount a folder with your WireGuard configs to `/wg-config`. If `CONFIG_FILE` isn't set, or the file it points to
doesn't exist, the container picks a random `.conf` file from `/wg-config` each time it starts. Random selection
skips the config used last time when another one is available, so a restart usually moves to a different server.

| Variable | Purpose |
| --- | --- |
| `CONFIG_FILE` | Path to a specific WireGuard config file to use, such as `/wg-config/my_wg.conf`. Leave unset to automatically pick one at random from `/wg-config`. |

## DNS and WireGuard endpoints

The container moves the Docker network interface into a separate network namespace so
Transmission only has the WireGuard interface. That means hostname lookups for a
WireGuard `Endpoint` cannot wait until after setup — there is no path to a resolver
in that namespace until the tunnel is up.

If your config uses a DNS name in `Endpoint` (instead of an IP), the container
resolves it **once at startup** via `dig` to `WG_BOOTSTRAP_DNS` (default `1.1.1.1`),
then rewrites the config to use that IP before moving the interface. That single
bootstrap lookup goes outside the tunnel; later DNS (with the default override to
Cloudflare) goes through WireGuard.

| Variable | Purpose |
| --- | --- |
| `WG_BOOTSTRAP_DNS` | IP of the resolver used only for Endpoint hostname lookup (default `1.1.1.1`). Must be an IP, not a hostname. |
| `ACCEPT_DNS_PRIVACY_LOSS=true` | Do not replace `/etc/resolv.conf`. Docker's embedded resolver (`127.0.0.11`) may then answer DNS outside the tunnel. Prefer leaving this unset. |

## Health check and self-healing

Docker runs a health check on the container every minute. It checks that DNS resolution works,
that `HEALTH_CHECK_HOST` answers a ping through the tunnel, that the WireGuard interface exists,
and that Transmission is running.

With `SELFHEAL=true`, the container also runs the health check on its own schedule, and if it fails
`MAX_SELFHEAL_FAILURES` times in a row (the default is 3 consecutive failures), the container shuts
itself down so Docker's restart policy starts it again. This requires a restart policy such as
`always`, `unless-stopped` or `on-failure`.

| Variable | Purpose |
| --- | --- |
| `HEALTH_CHECK_HOST` | Host used by the health check for its DNS lookup and ping (default `google.com`). |
| `SELFHEAL` | Set to `true` to restart the container when the health check keeps failing (default `false`). |
| `MAX_SELFHEAL_FAILURES` | Number of failed health checks in a row before restarting (default `3`). |
| `SELFHEAL_INTERVAL` | Seconds between self-heal health checks (default `60`). |

## Custom scripts

To run your own code at certain points while the container starts or stops, mount a folder to
`/scripts` and add any of these scripts to it. Each one is optional and only runs if it exists
and is executable (`chmod +x`).

| Script | Function |
| --- | --- |
| /scripts/wireguard-pre-start.sh | This shell script will be executed before WireGuard starts |
| /scripts/wireguard-post-config.sh | This shell script will be executed after WireGuard config |
| /scripts/transmission-pre-start.sh | This shell script will be executed before transmission starts |
| /scripts/transmission-post-start.sh | This shell script will be executed after transmission starts |
| /scripts/routes-post-start.sh | This shell script will be executed after routes are added |
| /scripts/transmission-pre-stop.sh | This shell script will be executed before transmission stops |
| /scripts/transmission-post-stop.sh | This shell script will be executed after transmission stops |
| /scripts/update-port.sh | This shell script will be started in the background after transmission starts, to keep the forwarded port updated |

For ProtonVPN port forwarding, place this script in `/scripts`:\
[update-port.sh](https://github.com/BigRedBrent/vpn-configs-contrib/blob/patch-3/openvpn/protonvpn/update-port.sh)

The scripts run one at a time, and startup continues once each one finishes. `update-port.sh` is
the exception, since it's meant to keep running for as long as the container does.

The Transmission scripts receive the same arguments as in `haugene/transmission-openvpn`, so existing
scripts keep working: device, tun MTU, link MTU, local tunnel address, remote tunnel address (empty
with WireGuard) and script context (`init`).

`transmission-pre-stop.sh` runs while Transmission and the tunnel are still up. Docker waits 10 seconds
by default before force-stopping a container, so set `stop_grace_period` if your stop scripts need longer.

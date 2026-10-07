#!/usr/bin/env bash
# Repack a Moonlight TV .ipk so it can persist settings and pairing on older webOS TVs.
#
# Moonlight stores its config in $HOME/conf (HOME = the app's install dir). On webOS 3.x
# developer-mode installs, that dir is root-owned and not writable by the app's uid, so
# Moonlight falls back to /tmp and forgets the pairing on every power-off. Shipping
# pre-created, world-writable conf/ and cache/ dirs inside the package fixes that.
#
# Usage: repack-moonlight-ipk.sh com.limelight.webos_X.Y.Z_arm.ipk [out.ipk]
set -euo pipefail

in=$(realpath "$1")
out=$(realpath -m "${2:-${in%.ipk}_writable.ipk}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cd "$work"
ar x "$in"
mkdir data
tar xzf data.tar.gz -C data
app=$(echo data/usr/palm/applications/*)
mkdir -p "$app/conf" "$app/cache"
chmod 777 "$app/conf" "$app/cache"
tar czf data.tar.gz --owner=0 --group=0 -C data .
rm -f "$out"
ar rc "$out" debian-binary control.tar.gz data.tar.gz
echo "wrote $out"

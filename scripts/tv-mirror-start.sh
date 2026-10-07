#!/usr/bin/env bash
# One-click "mirror this laptop to the TV": wake the TV over LAN, start Sunshine,
# reinstall Moonlight if Developer Mode expiry deleted it, then open Moonlight.
#
# Config (optional): ~/.config/lg-mirror/config, shell syntax:
#   TV_MAC=78:5D:C8:28:71:6E   DEVICE=lgtv   IPK=~/.local/share/lg-mirror/moonlight.ipk
set -uo pipefail
export OPENSSL_ENABLE_SHA1_SIGNATURES=1 PATH="$HOME/.local/bin:$PATH"

conf=${XDG_CONFIG_HOME:-$HOME/.config}/lg-mirror/config
# shellcheck source=/dev/null
[ -f "$conf" ] && . "$conf"
DEVICE=${DEVICE:-lgtv}
IPK=${IPK:-${XDG_DATA_HOME:-$HOME/.local/share}/lg-mirror/moonlight.ipk}
APP=com.limelight.webos
SUNSHINE=app-dev.lizardbyte.app.Sunshine

say()  { notify-send -a "TV Mirror" -i video-television -r 7351 "TV Mirror" "$1"; }
fail() { notify-send -a "TV Mirror" -i dialog-error -u critical "TV Mirror" "$1"; exit 1; }

tv_ip=$(python3 - "$DEVICE" <<'EOF'
import json, os, sys
for d in json.load(open(os.path.expanduser("~/.webos/tv/novacom-devices.json"))):
    if d["name"] == sys.argv[1]:
        print(d["host"])
EOF
)
[ -n "$tv_ip" ] || fail "No webOS device '$DEVICE' configured (ares-setup-device)."

wake() {
    python3 - "$1" <<'EOF'
import socket, sys
pkt = b"\xff" * 6 + bytes.fromhex(sys.argv[1].replace(":", "")) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for port in (9, 7):
    s.sendto(pkt, ("255.255.255.255", port))
EOF
}

say "Starting…"
systemctl --user start "$SUNSHINE" || fail "Couldn't start Sunshine."

if ! ping -c1 -W1 "$tv_ip" >/dev/null 2>&1; then
    [ -n "${TV_MAC:-}" ] || fail "TV is off and TV_MAC isn't set - turn the TV on and try again."
    say "Turning the TV on…"
    wake "$TV_MAC"
    for _ in $(seq 60); do ping -c1 -W1 "$tv_ip" >/dev/null 2>&1 && break; sleep 1; done
    ping -c1 -W1 "$tv_ip" >/dev/null 2>&1 || fail "The TV didn't wake up. Turn it on with the remote and try again."
fi

# The Developer Mode SSH service comes up a few seconds after the network does.
apps=""
for _ in $(seq 12); do
    apps=$(timeout 20 ares-install -d "$DEVICE" --list 2>/dev/null) && break
    sleep 5
done
[ -n "$apps" ] || fail "Can't reach Developer Mode on the TV. Open the Developer Mode app on the TV and check it's ON."

if ! grep -q "$APP" <<<"$apps"; then
    [ -f "$IPK" ] || fail "Moonlight is missing from the TV and $IPK doesn't exist."
    say "Reinstalling Moonlight on the TV…"
    ares-install -d "$DEVICE" "$IPK" >/dev/null 2>&1 || fail "Reinstalling Moonlight failed."
fi

ares-launch -d "$DEVICE" "$APP" >/dev/null 2>&1 || fail "Couldn't open Moonlight on the TV."
say "On the TV: pick this laptop, then Desktop."

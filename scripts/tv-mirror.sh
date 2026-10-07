#!/usr/bin/env bash
# One-click mirroring to the TV. With no argument it toggles: if Moonlight is showing this
# laptop on the TV, stop; otherwise start.
#
# start:  start Sunshine, wake the TV over LAN, reinstall Moonlight (and restore its pairing)
#         if Developer Mode expiry deleted it, then open Moonlight with launch params that
#         stream Desktop right away.
# stop:   close Moonlight on the TV and stop Sunshine (frees ~440 MB RAM and lets the GPU sleep).
# backup: save Moonlight's settings + pairing keys from the TV (done automatically on start).
#
# Config (optional): ~/.config/lg-mirror/config, shell syntax:
#   TV_MAC=78:5D:C8:28:71:6E  DEVICE=lgtv  APP_NAME=Desktop  IPK=~/.local/share/lg-mirror/moonlight.ipk
# The app's numeric GameStream ID is looked up from Sunshine each time using Moonlight's
# backed-up client cert; APP_ID is only a fallback.
set -uo pipefail
export OPENSSL_ENABLE_SHA1_SIGNATURES=1 PATH="$HOME/.local/bin:$PATH"

conf=${XDG_CONFIG_HOME:-$HOME/.config}/lg-mirror/config
# shellcheck source=/dev/null
[ -f "$conf" ] && . "$conf"
DEVICE=${DEVICE:-lgtv}
APP_NAME=${APP_NAME:-Desktop}
APP_ID=${APP_ID:-881448767}
IPK=${IPK:-${XDG_DATA_HOME:-$HOME/.local/share}/lg-mirror/moonlight.ipk}
BACKUP=${XDG_CONFIG_HOME:-$HOME/.config}/lg-mirror/moonlight-conf.tar.gz
APP=com.limelight.webos
APP_DIR=/media/developer/apps/usr/palm/applications/$APP
SUNSHINE=app-dev.lizardbyte.app.Sunshine

say()  { notify-send -a "TV Mirror" -i video-television -r 7351 "TV Mirror" "$1"; }
fail() { notify-send -a "TV Mirror" -i dialog-error -r 7351 -u critical "TV Mirror" "$1"; exit 1; }
tv_up() { ping -c1 -W1 "$tv_ip" >/dev/null 2>&1; }

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

host_uuid() {  # Sunshine's GameStream unique id; it answers a few seconds after starting
    for _ in $(seq 15); do
        id=$(curl -s --max-time 2 http://localhost:47989/serverinfo | grep -oP '(?<=<uniqueid>)[^<]+')
        [ -n "$id" ] && { echo "$id"; return; }
        sleep 1
    done
}

tv_run() { timeout 40 ares-novacom -d "$DEVICE" --run "$1" 2>/dev/null | grep -v "^\[Info\]"; }

# Moonlight keeps its settings and pairing keys in $APP_DIR/conf, which a reinstall wipes.
# There's no file transfer for TV devices (ares-push/pull are disabled), so go via base64.
backup_conf() {
    local tmp
    tmp=$(mktemp) || return 1
    tv_run "cd $APP_DIR/conf && tar cz key hosts.ini moonlight.ini | base64" | base64 -d > "$tmp" 2>/dev/null
    if tar tzf "$tmp" 2>/dev/null | grep -q 'key/key.pem'; then
        chmod 600 "$tmp" && mv "$tmp" "$BACKUP"
    else
        rm -f "$tmp"; return 1
    fi
}

restore_conf() {
    [ -f "$BACKUP" ] || return 1
    tv_run "mkdir -p $APP_DIR/conf && cd $APP_DIR/conf && echo $(base64 -w0 "$BACKUP") | base64 -d | tar xz \
        && chmod 777 key && chmod 644 key/* && chmod 666 hosts.ini moonlight.ini"
}

app_id() {  # GameStream ID of $APP_NAME, via Sunshine's /applist with Moonlight's client cert
    local dir id=""
    if [ -f "$BACKUP" ] && dir=$(mktemp -d); then
        tar xzf "$BACKUP" -C "$dir" key 2>/dev/null &&
            id=$(curl -sk --max-time 5 --cert "$dir/key/client.pem" --key "$dir/key/key.pem" \
                    "https://localhost:47984/applist?uniqueid=$(tr -d '\n' < "$dir/key/uniqueid.dat")" |
                 python3 -c 'import sys, xml.etree.ElementTree as ET
for a in ET.fromstring(sys.stdin.read()).iter("App"):
    if a.findtext("AppTitle") == sys.argv[1]: print(a.findtext("ID"))' "$APP_NAME" 2>/dev/null)
        rm -rf "$dir"
    fi
    echo "${id:-$APP_ID}"
}

start() {
    say "Starting…"
    systemctl --user start "$SUNSHINE" || fail "Couldn't start Sunshine."

    if ! tv_up; then
        [ -n "${TV_MAC:-}" ] || fail "The TV is off. Turn it on with the remote and click again."
        say "Turning the TV on…"
        wake "$TV_MAC"
        for _ in $(seq 60); do tv_up && break; sleep 1; done
        tv_up || fail "The TV didn't wake up. Turn it on with the remote and click again."
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
        restore_conf || say "Moonlight was reinstalled but its pairing couldn't be restored. Pair it again with the PIN shown on the TV."
    else
        # Refresh every time so a pairing made since (e.g. from Windows) isn't lost on a reinstall.
        backup_conf
    fi

    uuid=$(host_uuid)
    [ -n "$uuid" ] || fail "Sunshine isn't responding."
    # Launch params only apply on a fresh start, so close any running instance first.
    timeout 20 ares-launch -d "$DEVICE" --close "$APP" >/dev/null 2>&1
    timeout 30 ares-launch -d "$DEVICE" "$APP" \
        -p "{\"host_uuid\":\"$uuid\",\"host_app_id\":$(app_id)}" >/dev/null 2>&1 \
        || fail "Couldn't open Moonlight on the TV."
    say "Mirroring to the TV. Click the icon again to stop."
}

stop() {
    tv_up && timeout 20 ares-launch -d "$DEVICE" --close "$APP" >/dev/null 2>&1
    systemctl --user stop "$SUNSHINE"
    say "Stopped."
}

mirroring() {
    systemctl --user -q is-active "$SUNSHINE" && tv_up &&
        timeout 20 ares-launch -d "$DEVICE" --running 2>/dev/null | grep -q "$APP"
}

case "${1:-toggle}" in
    start) start ;;
    stop) stop ;;
    backup) backup_conf && echo "saved $BACKUP" || { echo "backup failed" >&2; exit 1; } ;;
    toggle) if mirroring; then stop; else start; fi ;;
    *) echo "usage: $0 [start|stop|toggle|backup]" >&2; exit 2 ;;
esac

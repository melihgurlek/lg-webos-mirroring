#!/usr/bin/env bash
# Stop mirroring: close Moonlight on the TV and stop Sunshine so it frees its RAM and the GPU.
set -uo pipefail
export OPENSSL_ENABLE_SHA1_SIGNATURES=1 PATH="$HOME/.local/bin:$PATH"

conf=${XDG_CONFIG_HOME:-$HOME/.config}/lg-mirror/config
# shellcheck source=/dev/null
[ -f "$conf" ] && . "$conf"

timeout 20 ares-launch -d "${DEVICE:-lgtv}" --close com.limelight.webos >/dev/null 2>&1
systemctl --user stop app-dev.lizardbyte.app.Sunshine
notify-send -a "TV Mirror" -i video-television -r 7351 "TV Mirror" "Stopped."

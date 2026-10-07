#!/usr/bin/env bash
# Install "Mirror to TV" / "Stop Mirroring" launchers (app menu + desktop) and stash the
# Moonlight ipk the start script reinstalls from.
# Usage: install-desktop-icons.sh [moonlight_writable.ipk] [TV_MAC]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bin=$HOME/.local/bin
data=${XDG_DATA_HOME:-$HOME/.local/share}
conf=${XDG_CONFIG_HOME:-$HOME/.config}/lg-mirror
desktop=$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")

mkdir -p "$bin" "$data/applications" "$data/lg-mirror" "$conf" "$desktop"
install -m 755 "$here/tv-mirror-start.sh" "$bin/tv-mirror-start"
install -m 755 "$here/tv-mirror-stop.sh" "$bin/tv-mirror-stop"
[ -n "${1:-}" ] && install -m 644 "$1" "$data/lg-mirror/moonlight.ipk"
[ -n "${2:-}" ] && echo "TV_MAC=$2" > "$conf/config"

entry() {  # file name exec icon
    cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Exec=$3
Icon=$4
Terminal=false
Categories=AudioVideo;
EOF
    chmod +x "$1"
}
for dir in "$data/applications" "$desktop"; do
    entry "$dir/tv-mirror-start.desktop" "Mirror to TV" "$bin/tv-mirror-start" video-television
    entry "$dir/tv-mirror-stop.desktop" "Stop Mirroring" "$bin/tv-mirror-stop" media-playback-stop
done
# KDE asks before running untrusted desktop-folder launchers; mark ours as trusted.
for f in "$desktop"/tv-mirror-{start,stop}.desktop; do
    gio set "$f" metadata::trusted true 2>/dev/null || true
done
echo "Installed. Look for 'Mirror to TV' on the desktop and in the app menu."

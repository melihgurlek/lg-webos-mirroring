#!/usr/bin/env bash
# Install the "Mirror to TV" toggle launcher (app menu + desktop) and stash the Moonlight
# ipk it reinstalls from. The launcher runs scripts/tv-mirror.sh straight from this repo,
# so edits and `git pull` apply immediately (moving the repo means re-running this).
# Usage: install-desktop-icons.sh [moonlight_writable.ipk] [TV_MAC]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bin=$HOME/.local/bin
data=${XDG_DATA_HOME:-$HOME/.local/share}
conf=${XDG_CONFIG_HOME:-$HOME/.config}/lg-mirror
desktop=$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")

mkdir -p "$bin" "$data/applications" "$data/lg-mirror" "$conf" "$desktop"
script=$here/tv-mirror.sh
chmod +x "$script"
ln -sfn "$script" "$bin/tv-mirror"   # for `tv-mirror stop` etc. in a terminal
# Remove the old separate start/stop launchers.
rm -f "$bin"/tv-mirror-{start,stop} "$data/applications"/tv-mirror-{start,stop}.desktop "$desktop"/tv-mirror-{start,stop}.desktop
[ -n "${1:-}" ] && install -m 644 "$1" "$data/lg-mirror/moonlight.ipk"
if [ -n "${2:-}" ]; then
    touch "$conf/config"
    sed -i '/^TV_MAC=/d' "$conf/config"
    echo "TV_MAC=$2" >> "$conf/config"
fi

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
    entry "$dir/tv-mirror.desktop" "Mirror to TV" "$script" video-television
done
# KDE asks before running untrusted desktop-folder launchers; mark ours as trusted.
gio set "$desktop/tv-mirror.desktop" metadata::trusted true 2>/dev/null || true
echo "Installed. Click 'Mirror to TV' on the desktop or in the app menu to start, again to stop."

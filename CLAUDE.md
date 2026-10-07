# CLAUDE.md

Screen mirroring from a dual-boot laptop (Fedora KDE + Windows 11) to an LG webOS 3.5 TV with Sunshine + Moonlight TV. See README.md for setup and FINDINGS.md for the why.

- `scripts/*.sh` are the Linux scripts, and `scripts/windows/*.ps1` are the Windows ports of the same scripts. The user switches between the two OSes often, so a change on one side must never break the other.
- Linux and Windows deliberately have **separate Sunshine identities and pairings**: "Laptop" on Linux and "Laptop (Windows)" on Windows. Don't try to merge or sync them.
- Moonlight's settings (resolution, bitrate, decoder) live on the TV in `conf/moonlight.ini` and are shared by both OSes.
- On the Windows side, the user doesn't want Sunshine to autostart, and the second click of the shortcut stops it.

## Handoff from the Linux session (2026-10-07): read this, act on it, then delete this section

The Windows handoff was handled on Linux: the backup was refreshed (both pairings are in it), the ipk was already 1.6.36, and the Linux icon was verified. Two changes in `scripts/windows/tv-mirror.ps1` were only parse-checked, never run on Windows. Test them:

1. **Backup refresh on every start** (`fd0409e`). `Start-Mirror` now calls `Backup-Conf` on every start when Moonlight is installed, not only when no backup exists. After a click, `%APPDATA%\lg-mirror\moonlight-conf.tar.gz` should have a new timestamp, and `tar xzOf <it> hosts.ini` should list both "Laptop" and "Laptop (Windows)".
2. **Finding the TV by MAC after a DHCP IP change** (`ef1b53c`, the `Locate-Tv` function). It needs `TV_MAC` in `%APPDATA%\lg-mirror\config`.
   - **Neighbour-table path:** check that nothing answers at 192.168.1.250, then run `ares-setup-device -m <DEVICE> -i "host=192.168.1.250"` and click the shortcut. `%LOCALAPPDATA%\lg-mirror\tv-mirror.log` should show `TV moved from 192.168.1.250 to 192.168.1.92`, `ares-setup-device --list` should show .92 again, and the stream should start.
   - **Ping-sweep path** (couldn't be tested on Linux without sudo): repeat the above, but before clicking, clear the TV from the neighbour cache in an admin shell with `Remove-NetNeighbor -IPAddress 192.168.1.92 -Confirm:$false` and confirm with `Get-NetNeighbor -IPAddress 192.168.1.92`. Things to watch: the `LinkLayerAddress` format (`78-5D-C8-28-71-6E`) matching the config MAC, `Get-NetRoute` picking the right adapter, and `SendPingAsync`/`WaitAll` working in the PowerShell the shortcut uses.
   - A second click should still stop it. If a fix is needed, make the same fix in `scripts/tv-mirror.sh` if it applies there too.

Then delete this section.

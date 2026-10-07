# CLAUDE.md

Screen mirroring from a dual-boot laptop (Fedora KDE + Windows 11) to an LG webOS 3.5 TV with Sunshine + Moonlight TV. See README.md for setup and FINDINGS.md for the why.

- `scripts/*.sh` are the Linux scripts, and `scripts/windows/*.ps1` are the Windows ports of the same scripts. The user switches between the two OSes often, so a change on one side must never break the other.
- Linux and Windows deliberately have **separate Sunshine identities and pairings**: "Laptop" on Linux and "Laptop (Windows)" on Windows. Don't try to merge or sync them.
- Moonlight's settings (resolution, bitrate, decoder) live on the TV in `conf/moonlight.ini` and are shared by both OSes.
- On the Windows side, the user doesn't want Sunshine to autostart, and the second click of the shortcut stops it.

## Handoff from the Windows session (2026-10-07): read this, act on it, then delete this section

Things changed on the shared TV while Windows was booted. Check these on Linux:

1. **The TV's IP changed from 192.168.1.108 to 192.168.1.92** (DHCP). Linux's `~/.webos/tv/novacom-devices.json` may still have the old IP. Check with `ares-setup-device --list` and fix with `ares-setup-device -m lgtv -i "host=192.168.1.92"` (use whatever the Linux device name is). Suggest a DHCP reservation for the TV's MAC `78:5D:C8:28:71:6E` on the router.
2. **Moonlight on the TV was reinstalled** from a repacked v1.6.36 ipk, because the installed copy had a root-owned `conf/` that the app couldn't write. `conf/` was restored from a backup, so the Linux pairing and the settings survived. `conf/hosts.ini` now has two hosts: `E080CA6D-…` "Laptop" (Linux) and `3BC60B00-…` "Laptop (Windows)", with `selected = true` on the Windows one. `tv-mirror.sh` launches by `host_uuid`, so the selection doesn't matter to it.
3. **The Linux backup is stale.** `~/.config/lg-mirror/moonlight-conf.tar.gz` predates the Windows pairing, and `tv-mirror.sh` only makes a backup when none exists. Run `scripts/tv-mirror.sh backup` once. Otherwise, if Developer Mode expires and Linux reinstalls Moonlight from this backup, the Windows pairing is lost. Consider (ask the user first) making `backup_conf` refresh whenever `conf/hosts.ini` on the TV differs from the backup. `scripts/windows/tv-mirror.ps1` has the same only-when-missing logic, so if you change it, change both.
4. **Optional:** `~/.local/share/lg-mirror/moonlight.ipk` may be older than 1.6.36. To match, download `com.limelight.webos_1.6.36_arm.ipk` from mariotaku/moonlight-tv releases, run it through `scripts/repack-moonlight-ipk.sh`, and re-run `scripts/install-desktop-icons.sh <ipk>`.

Then verify the Linux icon still starts and stops mirroring, and delete this section.

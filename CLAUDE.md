# CLAUDE.md

Screen mirroring from a dual-boot laptop (Fedora KDE + Windows 11) and a Windows 11 work laptop to an LG webOS 3.5 TV with Sunshine + Moonlight TV. See README.md for setup and FINDINGS.md for the why.

- `scripts/*.sh` are the Linux scripts, and `scripts/windows/*.ps1` are the Windows ports of the same scripts. The user switches between the two OSes and the two laptops often, so a change on one side must never break the other.
- Each machine deliberately has a **separate Sunshine identity and pairing**: "Laptop" on Linux, "Laptop (Windows)" on the dual-boot's Windows, "Laptop Work" on the work laptop. Don't try to merge or sync them. One click on any of them must connect, and they're never used at the same time.
- Moonlight's settings (resolution, bitrate, decoder) live on the TV in `conf/moonlight.ini` and are shared by all of them. Each start adds its own machine to `conf/hosts.ini` because mDNS doesn't reach the TV from the work laptop's Wi-Fi.
- The work laptop's PowerShell blocks the npm `.ps1` shims (execution policy set by IT). Use `ares-*.cmd`, and don't change the policy.
- On the Windows side, the user doesn't want Sunshine to autostart, and the second click of the shortcut stops it.

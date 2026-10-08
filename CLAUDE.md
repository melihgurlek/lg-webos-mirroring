# CLAUDE.md

Screen mirroring from a dual-boot laptop (Fedora KDE + Windows 11) to an LG webOS 3.5 TV with Sunshine + Moonlight TV. See README.md for setup and FINDINGS.md for the why.

- `scripts/*.sh` are the Linux scripts, and `scripts/windows/*.ps1` are the Windows ports of the same scripts. The user switches between the two OSes often, so a change on one side must never break the other.
- Linux and Windows deliberately have **separate Sunshine identities and pairings**: "Laptop" on Linux and "Laptop (Windows)" on Windows. Don't try to merge or sync them.
- Moonlight's settings (resolution, bitrate, decoder) live on the TV in `conf/moonlight.ini` and are shared by both OSes.
- On the Windows side, the user doesn't want Sunshine to autostart, and the second click of the shortcut stops it.

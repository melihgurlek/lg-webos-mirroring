# lg-webos-mirroring

Screen mirroring from a Fedora (KDE Wayland) laptop to a 2017 LG webOS TV (49SJ800V, webOS 3.5) whose Wi-Fi module is dead, so Miracast / Windows `Win + K` can't work.

**What works:** [Sunshine](https://github.com/LizardByte/Sunshine) on the laptop and [Moonlight TV](https://github.com/mariotaku/moonlight-tv) sideloaded onto the TV with LG Developer Mode. Everything goes over Ethernet, and you get 1080p60 with audio and barely noticeable lag.

The diagnosis, the dead ends and the quirks are written up in [FINDINGS.md](FINDINGS.md).

## Setup

1. **TV:** install LG's *Developer Mode* app, sign in with an LG developer account and enable it. Turn on *Key Server* temporarily.
2. **Laptop, webOS CLI:**
   ```sh
   npm install -g --prefix ~/.local @webos-tools/cli
   export OPENSSL_ENABLE_SHA1_SIGNATURES=1   # the TV only speaks ssh-rsa (SHA-1)
   ares-setup-device -a lgtv -i "username=prisoner" -i "host=<TV_IP>" -i "port=9922"
   ares-novacom --device lgtv --getkey        # enter the passphrase shown on the TV
   ares-setup-device -m lgtv -i "passphrase=<PASSPHRASE>"
   ```
3. **Moonlight TV:** download the `_arm.ipk` from its releases, then make it able to save settings and install it:
   ```sh
   scripts/repack-moonlight-ipk.sh com.limelight.webos_*_arm.ipk moonlight.ipk
   ares-install -d lgtv moonlight.ipk
   ```
4. **Sunshine:**
   ```sh
   sudo dnf copr enable lizardbyte/stable && sudo dnf install Sunshine
   cp config/sunshine.conf ~/.config/sunshine/sunshine.conf
   sunshine --creds <user> <password>
   ```
   Sunshine isn't autostarted: idle, it holds ~440 MB RAM and keeps the NVIDIA GPU awake. The desktop icon starts and stops it.
5. **Pair:** open Moonlight on the TV, select the laptop, then:
   ```sh
   SUNSHINE_USER=<user> SUNSHINE_PASS=<password> scripts/sunshine-pair.sh <PIN>
   ```
6. **Moonlight settings:** 1080p, 60 FPS, 30 Mbps, H.264, decoder *webOS SMP*. Set the TV picture mode to *Game*.

## Everyday use: one desktop icon

```sh
scripts/install-desktop-icons.sh moonlight.ipk <TV_MAC>
```

This adds a **Mirror to TV** icon to the desktop and app menu, so nobody needs a terminal or the TV remote.
- **Click once to start (~10 s).** It starts Sunshine and wakes the TV with Wake-on-LAN (this works over Ethernet when the TV is in standby). If Developer Mode expiry deleted Moonlight, it reinstalls it and restores the pairing and settings from a backup, so there's no new PIN. Then it opens Moonlight with launch params (`{"host_uuid": …, "host_app_id": …}`), so the Desktop stream starts by itself.
- **Click again to stop.** It closes Moonlight and stops Sunshine.

The launcher runs `scripts/tv-mirror.sh` straight from the repo, so re-run the installer if you move the repo. Moonlight's settings and keys are backed up to `~/.config/lg-mirror/moonlight-conf.tar.gz` on the first start (`tv-mirror backup` refreshes it). To stream a different Sunshine app, set `APP_NAME=` in `~/.config/lg-mirror/config`.

## Windows

The same setup works from a Windows 10/11 PC. `scripts/windows/` has PowerShell versions of the scripts; they only need what ships with Windows (PowerShell 5.1, `tar.exe`, `curl.exe`) plus Node.js for the webOS CLI.

If you downloaded the repo as a zip, unblock the scripts first: `Get-ChildItem -Recurse scripts | Unblock-File`. Run them as `powershell -ExecutionPolicy Bypass -File <script>`.

1. **TV:** same as step 1 above.
2. **webOS CLI** ([Node.js](https://nodejs.org) LTS required). `OPENSSL_ENABLE_SHA1_SIGNATURES` isn't needed on Windows:
   ```powershell
   npm install -g @webos-tools/cli
   ares-setup-device -a lgtv -i "username=prisoner" -i "host=<TV_IP>" -i "port=9922"
   ares-novacom --device lgtv --getkey
   ares-setup-device -m lgtv -i "passphrase=<PASSPHRASE>"
   ```
3. **Moonlight TV:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\windows\repack-moonlight-ipk.ps1 com.limelight.webos_X.Y.Z_arm.ipk moonlight.ipk
   ares-install -d lgtv moonlight.ipk
   ```
4. **Sunshine:** `winget install LizardByte.Sunshine` (or the installer from its releases). Copy `config\sunshine-windows.conf` to `C:\Program Files\Sunshine\config\sunshine.conf` and set credentials with `& "C:\Program Files\Sunshine\sunshine.exe" --creds <user> <password>` (as admin). Put the same values in `%APPDATA%\lg-mirror\config` as `SUNSHINE_USER=` and `SUNSHINE_PASS=` so the pairing script can use them. Allow Sunshine through Windows Firewall when asked (private networks).
5. **Pair:** select the PC in Moonlight on the TV, then:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\windows\sunshine-pair.ps1 <PIN>
   ```
6. **Moonlight settings:** same as step 6 above.
7. **One-click shortcut:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\windows\install-shortcuts.ps1 -Ipk moonlight.ipk -TvMac <TV_MAC>
   ```
   This adds **Mirror to TV** to the desktop and Start menu. It behaves like the Linux icon: double-click to start, double-click again to stop (this closes Moonlight and stops Sunshine), and Windows notifications show progress. Every click is logged to `%LOCALAPPDATA%\lg-mirror\tv-mirror.log`.

   Sunshine doesn't start with Windows. The installer asks for admin once to set its service to manual start and to let your account start and stop it, so clicks don't trigger UAC prompts. A start takes about 30 s on Windows, because Sunshine spends that long detecting displays and no config option shortens it. To make starts take about 6 s, set `KEEP_SUNSHINE=1`: stopping then leaves Sunshine idling at about 45 MB until reboot.

   Config lives in `%APPDATA%\lg-mirror\config` (`DEVICE=`, `TV_MAC=`, `APP_NAME=`, `KEEP_SUNSHINE=`, `SUNSHINE_USER=`, `SUNSHINE_PASS=`). The pairing backup is `%APPDATA%\lg-mirror\moonlight-conf.tar.gz` and the ipk used for reinstalls is `%LOCALAPPDATA%\lg-mirror\moonlight.ipk`. From a terminal you can run `tv-mirror.ps1 start|stop|backup`.

The Developer Mode renewal runs on GitHub Actions, so it works the same no matter which OS you use. To get the token on Windows, run `ares-novacom -d lgtv --run "cat /var/luna/preferences/devmode_enabled"` and store its output with `gh secret set LG_DEVMODE_TOKEN`.

## Keeping Developer Mode alive

Developer Mode expires after about 50 hours, and the TV then deletes sideloaded apps. The session lives on LG's servers, so `.github/workflows/renew-devmode.yml` renews it every 12 h from GitHub Actions, even when the TV and laptop are off. Setup:

```sh
# the token file on the TV holds the Dev Mode session token
OPENSSL_ENABLE_SHA1_SIGNATURES=1 ares-novacom -d lgtv --run "cat /var/luna/preferences/devmode_enabled" > token
gh secret set LG_DEVMODE_TOKEN < token && rm token
gh workflow run renew-devmode.yml
```

## Repo layout

| Path | What |
|---|---|
| `config/sunshine.conf` | Sunshine config: KWin capture plus NVENC (hybrid AMD/NVIDIA laptop) |
| `scripts/repack-moonlight-ipk.sh` | Adds writable `conf/` and `cache/` dirs so pairing survives power-off |
| `scripts/tv-mirror.sh` | One-click start/stop toggle; also `start`, `stop` and `backup` (linked by `install-desktop-icons.sh`) |
| `.github/workflows/renew-devmode.yml` | Renews Developer Mode every 12 h |
| `scripts/sunshine-pair.sh` | Submits a Moonlight PIN to Sunshine from the CLI |
| `scripts/windows/` | PowerShell versions of the scripts above for Windows (`install-shortcuts.ps1` replaces `install-desktop-icons.sh`) |
| `config/sunshine-windows.conf` | Sunshine config for Windows |
| `archived/browser-mirror/` | An earlier attempt that streams to the TV's built-in browser. Works, but has ~0.5 s+ lag and no audio |

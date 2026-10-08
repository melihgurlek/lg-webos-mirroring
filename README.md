# lg-webos-mirroring

Mirror a laptop's screen (Linux or Windows) to an old LG webOS TV with one click, even when the TV's Wi-Fi is broken.

The TV here is a 2017 LG 49SJ800V (webOS 3.5) with a dead Wi-Fi module, so Miracast and Windows `Win + K` can't work: both need Wi-Fi Direct. Instead, [Sunshine](https://github.com/LizardByte/Sunshine) runs on the laptop and [Moonlight TV](https://github.com/mariotaku/moonlight-tv) is sideloaded onto the TV with LG Developer Mode. Everything goes over Ethernet, and you get 1080p60 with audio and barely noticeable lag.

The diagnosis, the dead ends and the quirks are written up in [FINDINGS.md](FINDINGS.md).

## How it works

```
laptop: Sunshine (captures + encodes the screen)  ──Ethernet/LAN──▶  TV: Moonlight TV (decodes in hardware)
```

- **Sunshine** is a game-streaming server. It runs on the laptop only while mirroring.
- **Moonlight TV** is a native webOS client. Installing it needs LG *Developer Mode*, which expires after about 50 hours unless renewed. A GitHub Actions workflow here renews it.
- **`tv-mirror`** is the one-click toggle. It wakes the TV, starts Sunshine, reinstalls Moonlight if it was deleted, and starts the stream. Clicking it again stops everything.

## Requirements

- An LG webOS TV (tested on webOS 3.5) on the same LAN as the laptop. Ethernet is fine.
- An LG developer account (free) for Developer Mode.
- A GitHub account to fork this repo and run the renewal workflow.
- On the laptop: Fedora KDE (Wayland), or Windows 10/11. Other Linux distributions should work with small changes. `config/sunshine.conf` is set up for a hybrid AMD + NVIDIA laptop, so see [FINDINGS.md](FINDINGS.md#sunshine-on-a-hybrid-gpu-kde-wayland-laptop) if your GPU is different.
- The TV's IP and wired MAC address. Your router's list of connected devices shows both.

## Setup on Linux

1. **TV:** install LG's *Developer Mode* app from the LG Content Store, sign in with your LG developer account and enable Developer Mode. Turn on *Key Server* for now; you only need it for step 2.
2. **webOS CLI** on the laptop:
   ```sh
   npm install -g --prefix ~/.local @webos-tools/cli
   export OPENSSL_ENABLE_SHA1_SIGNATURES=1   # the TV only speaks ssh-rsa (SHA-1)
   ares-setup-device -a lgtv -i "username=prisoner" -i "host=<TV_IP>" -i "port=9922"
   ares-novacom --device lgtv --getkey        # enter the passphrase shown in the Developer Mode app
   ares-setup-device -m lgtv -i "passphrase=<PASSPHRASE>"
   ```
3. **Moonlight TV:** download `com.limelight.webos_X.Y.Z_arm.ipk` from its [releases](https://github.com/mariotaku/moonlight-tv/releases). Repack it so it can save its settings and pairing, then install it:
   ```sh
   scripts/repack-moonlight-ipk.sh com.limelight.webos_*_arm.ipk moonlight.ipk
   ares-install -d lgtv moonlight.ipk
   ```
4. **Sunshine:**
   ```sh
   sudo dnf copr enable lizardbyte/stable && sudo dnf install Sunshine
   mkdir -p ~/.config/sunshine && cp config/sunshine.conf ~/.config/sunshine/sunshine.conf
   sunshine --creds <user> <password>
   ```
   Don't set Sunshine to start on login. Even when idle, it uses about 440 MB of RAM and keeps the NVIDIA GPU awake. The desktop icon (step 7) starts and stops it.
5. **Pair:** start Sunshine, open Moonlight on the TV and select the laptop. The TV shows a PIN. Then run:
   ```sh
   SUNSHINE_USER=<user> SUNSHINE_PASS=<password> scripts/sunshine-pair.sh <PIN>
   ```
6. **Moonlight settings** (in Moonlight on the TV): 1080p, 60 FPS, 30 Mbps, H.264, decoder *webOS SMP*. Also set the TV's picture mode to *Game*.
7. **Desktop icon:**
   ```sh
   scripts/install-desktop-icons.sh moonlight.ipk <TV_MAC>
   ```
   This adds **Mirror to TV** to the desktop and the app menu. The icon runs `scripts/tv-mirror.sh` straight from the repo, so if you move the repo, run the installer again.
8. Set up [Developer Mode renewal](#keeping-developer-mode-alive).

## Setup on Windows

`scripts/windows/` has PowerShell versions of the Linux scripts. Besides Node.js for the webOS CLI, they only need what ships with Windows: PowerShell 5.1, `tar.exe` and `curl.exe`.

If you downloaded the repo as a zip, unblock the scripts first with `Get-ChildItem -Recurse scripts | Unblock-File`. Run each script as `powershell -ExecutionPolicy Bypass -File <script>`.

1. **TV:** same as Linux step 1.
2. **webOS CLI** (needs [Node.js](https://nodejs.org) LTS). Windows doesn't need `OPENSSL_ENABLE_SHA1_SIGNATURES`:
   ```powershell
   npm install -g @webos-tools/cli
   ares-setup-device -a lgtv -i "username=prisoner" -i "host=<TV_IP>" -i "port=9922"
   ares-novacom --device lgtv --getkey
   ares-setup-device -m lgtv -i "passphrase=<PASSPHRASE>"
   ```
3. **Moonlight TV:** download the ipk as in Linux step 3, then:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\windows\repack-moonlight-ipk.ps1 com.limelight.webos_X.Y.Z_arm.ipk moonlight.ipk
   ares-install -d lgtv moonlight.ipk
   ```
4. **Sunshine:**
   - Install it with `winget install LizardByte.Sunshine`, or with the installer from its releases.
   - Copy `config\sunshine-windows.conf` to `C:\Program Files\Sunshine\config\sunshine.conf`.
   - In an admin shell, set the credentials with `& "C:\Program Files\Sunshine\sunshine.exe" --creds <user> <password>`.
   - Put the same credentials in `%APPDATA%\lg-mirror\config` as `SUNSHINE_USER=` and `SUNSHINE_PASS=` lines, so the pairing script can use them.
   - When Windows Firewall asks, allow Sunshine on private networks.
5. **Pair:** select the PC in Moonlight on the TV, then:
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\windows\sunshine-pair.ps1 <PIN>
   ```
6. **Moonlight settings:** same as Linux step 6.
7. **One-click shortcut:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\windows\install-shortcuts.ps1 -Ipk moonlight.ipk -TvMac <TV_MAC>
   ```
   This adds **Mirror to TV** to the desktop and the Start menu. The installer asks for admin rights once. It sets Sunshine's service to start manually rather than with Windows, and lets your account start and stop it, so clicks don't bring up UAC prompts.
8. Set up [Developer Mode renewal](#keeping-developer-mode-alive).

On a dual-boot laptop, Linux and Windows are separate Sunshine hosts ("Laptop" and "Laptop (Windows)"), so pair each one. Moonlight's settings on the TV are shared by both.

## Everyday use

- **Click once to start.** It starts Sunshine and wakes the TV with Wake-on-LAN, which works over Ethernet from standby. If the router gave the TV a new IP, it finds the TV by its MAC and updates the `ares` device. If Developer Mode expired and the TV deleted Moonlight, it reinstalls it and restores the pairing and settings from a backup, so you don't need a new PIN. Then it opens Moonlight and the Desktop stream starts by itself.
- **Click again to stop.** It closes Moonlight and stops Sunshine.

A start takes about 10 s on Linux and about 30 s on Windows, where Sunshine spends that long detecting displays and no config option shortens it. On Windows, setting `KEEP_SUNSHINE=1` brings it down to about 6 s. With that set, stopping leaves Sunshine idling at about 45 MB until reboot.

Notifications show progress. Moonlight's settings and keys are backed up from the TV on every start. From a terminal, you can also run `tv-mirror start|stop|backup` (`tv-mirror.ps1` on Windows).

| | Linux | Windows |
|---|---|---|
| Config file | `~/.config/lg-mirror/config` | `%APPDATA%\lg-mirror\config` |
| Settings | `DEVICE=`, `TV_MAC=`, `APP_NAME=`, `IPK=` | same, plus `KEEP_SUNSHINE=`, `SUNSHINE_USER=`, `SUNSHINE_PASS=` |
| Pairing backup | `~/.config/lg-mirror/moonlight-conf.tar.gz` | `%APPDATA%\lg-mirror\moonlight-conf.tar.gz` |
| ipk for reinstalls | `~/.local/share/lg-mirror/moonlight.ipk` | `%LOCALAPPDATA%\lg-mirror\moonlight.ipk` |
| Log | — | `%LOCALAPPDATA%\lg-mirror\tv-mirror.log` |

To stream a different Sunshine app than Desktop, set `APP_NAME=`.

## Keeping Developer Mode alive

Developer Mode expires after about 50 hours, and the TV then deletes sideloaded apps. The session lives on LG's servers, so `.github/workflows/renew-devmode.yml` renews it every 12 h from GitHub Actions, even when the TV and the laptop are off.

To set it up, fork this repo, then store the session token from the TV as a secret in your fork:

```sh
# Linux (on Windows, leave out OPENSSL_ENABLE_SHA1_SIGNATURES=1)
OPENSSL_ENABLE_SHA1_SIGNATURES=1 ares-novacom -d lgtv --run "cat /var/luna/preferences/devmode_enabled" > token
gh secret set LG_DEVMODE_TOKEN < token && rm token
gh workflow run renew-devmode.yml
```

GitHub turns off scheduled workflows in public repos after 60 days without commits. If renewal stops, re-enable the workflow in the *Actions* tab. If the TV deleted Moonlight in the meantime, the next click reinstalls it.

## Repo layout

| Path | What |
|---|---|
| `scripts/tv-mirror.sh` | The one-click start/stop toggle; also takes `start`, `stop` and `backup` |
| `scripts/install-desktop-icons.sh` | Installs the **Mirror to TV** icon |
| `scripts/repack-moonlight-ipk.sh` | Adds writable `conf/` and `cache/` dirs so the pairing survives power-off |
| `scripts/sunshine-pair.sh` | Submits a Moonlight PIN to Sunshine from the CLI |
| `scripts/windows/` | PowerShell versions of the scripts above (`install-shortcuts.ps1` replaces `install-desktop-icons.sh`) |
| `config/sunshine.conf` | Sunshine config for Linux: KWin capture plus NVENC (hybrid AMD/NVIDIA laptop) |
| `config/sunshine-windows.conf` | Sunshine config for Windows |
| `.github/workflows/renew-devmode.yml` | Renews Developer Mode every 12 h |
| `archived/browser-mirror/` | An earlier attempt that streamed to the TV's built-in browser. It works, but has 0.5 s+ of lag and no audio |

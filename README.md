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
   Sunshine isn't autostarted: idle, it holds ~440 MB RAM and keeps the NVIDIA GPU awake. The desktop icons start and stop it.
5. **Pair:** open Moonlight on the TV, select the laptop, then:
   ```sh
   SUNSHINE_USER=<user> SUNSHINE_PASS=<password> scripts/sunshine-pair.sh <PIN>
   ```
6. **Moonlight settings:** 1080p, 60 FPS, 30 Mbps, H.264, decoder *webOS SMP*. Set the TV picture mode to *Game*.

## Everyday use: desktop icons

```sh
scripts/install-desktop-icons.sh moonlight.ipk <TV_MAC>
```

This adds **Mirror to TV** and **Stop Mirroring** to the desktop and app menu, so nobody needs a terminal.
- **Mirror to TV** starts Sunshine and wakes the TV with Wake-on-LAN (this works over Ethernet when the TV is in standby). If Developer Mode expiry deleted Moonlight, it reinstalls it, then opens Moonlight. On the TV: pick the laptop, then *Desktop*.
- **Stop Mirroring** closes Moonlight and stops Sunshine.

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
| `scripts/tv-mirror-start.sh`, `tv-mirror-stop.sh` | One-click start/stop (installed by `install-desktop-icons.sh`) |
| `.github/workflows/renew-devmode.yml` | Renews Developer Mode every 12 h |
| `scripts/sunshine-pair.sh` | Submits a Moonlight PIN to Sunshine from the CLI |
| `archived/browser-mirror/` | An earlier attempt that streams to the TV's built-in browser. Works, but has ~0.5 s+ lag and no audio |

# Findings

Notes from debugging screen mirroring on an LG **49SJ800V-ZB** (webOS 3.5, firmware 06.10.65, board `M16P_DVB_EU`) connected by Ethernet, mirroring from a Fedora 44 KDE Plasma (Wayland) laptop with hybrid AMD Radeon (Cezanne) + NVIDIA RTX 3050 Mobile graphics.

## 1. Why mirroring stopped working

Two different features get called "casting":

| Feature | Transport | Works over Ethernet? |
|---|---|---|
| Casting to YouTube/Netflix apps (DIAL) | Home LAN; the TV app fetches the stream itself | Yes |
| Miracast / "Screen Share" / Windows `Win + K` | **Wi-Fi Direct**, a peer-to-peer link to the TV's own radio | **No** |

Evidence that the Wi-Fi module is dead, not just disabled:

- **The webOS connection manager reports no Wi-Fi adapter.** Over the SSAP API (port 3000), `com.webos.service.connectionmanager/getinfo` returns only
  ```json
  { "wiredInfo": { "macAddress": "78:5D:C8:28:71:6E" }, "returnValue": true }
  ```
  A healthy TV also returns a `wifiInfo` entry, even when Ethernet is in use.
- **The TV never appears in a Wi-Fi Direct scan.** A 25 s P2P scan from the laptop, run through NetworkManager's `WifiP2P.StartFind` over D-Bus, found two neighbouring Samsung TVs but nothing from LG.
- In the TV's settings, the Wi-Fi option exists but can't be turned on.

So Miracast can't be fixed in software. A driver wouldn't help either: webOS can't see the hardware at all. The hardware fixes are to reseat or replace the Wi-Fi/BT module, a small board on an internal USB-style cable, or to plug in an HDMI dongle.

## 2. Attempt 1: stream to the TV's built-in browser (archived)

`archived/browser-mirror/` captures the screen through the xdg-desktop-portal (PipeWire), encodes with GStreamer `nvh264enc`, remuxes to fragmented MP4 with ffmpeg, sends it over a WebSocket, and plays it with Media Source Extensions in the TV browser. The TV browser is opened remotely through SSAP `system.launcher/open`.

The TV browser's capabilities, probed with a test page:
- UA: `Chrome/38.0.2125.122 … SmartTV/7.5` (Chromium 38, so ES5 only and no WebAssembly)
- MSE: yes, H.264 up to High profile (level 5.1 accepted); WebSocket yes; WebRTC objects present
- Viewport `1280x606` CSS px at DPR 1.5 while the browser toolbar is visible

### The LG MSE quirk

I tested fMP4 variants side by side on the TV:

| Variant | Result |
|---|---|
| `frag_keyframe+empty_moov+default_base_moof` | plays |
| Same without `default_base_moof` | rejected (`MEDIA_ERR_SRC_NOT_SUPPORTED`) |
| One fragment per frame (`frag_every_frame`) | rejected |
| 2, 3, 5 or 10 frames per fragment | first fragment buffers, then rejected |
| Per-frame fragments rewritten with explicit trun fields | rejected |
| Per-frame fragments with the first sample **flagged** as sync | accepted and "plays", but only real IDR frames are displayed |
| All-intra encode (`gop-size=1`) with per-frame fragments | plays smoothly |

**Every media segment must begin with a sync sample.** The parser only checks the flag, but the decoder seems to reset at each flagged "keyframe", so faked flags show one picture per real GOP, which looked like 5 s per frame. The working configuration is all-intra H.264. At constant QP 22 that's about 35–45 Mbit/s at full motion.

### Remaining problems (why it was archived)

- The TV needs about 0.5 s of buffer to play without stalling, and its reported `currentTime` is coarse, so lag estimates jitter by ±1 s. Aggressive catch-up (seek when lag > 0.6 s) caused about 1.7 skips per second.
- The capture is variable-frame-rate (PipeWire damage-driven), and ffmpeg guesses each per-frame fragment's last-sample duration. That leaves tiny gaps in the TV's buffer, and the TV stalls at each one (`waiting` events). Probable fix, not yet implemented: hold one frame and set each sample's duration to `next_tfdt - this_tfdt`.
- There's no audio.

Network throughput was never the bottleneck: about 45 Mbit/s with an empty send queue and no drops.

## 3. Attempt 2: Sunshine + Moonlight TV (current)

A web app built with the webOS SDK would run on the same Chromium 38 engine with the same limits. A **native** app, which Developer Mode allows, can use the TV's hardware decoder directly. Moonlight TV is exactly that.

### webOS / Developer Mode quirks

- **SSH to the TV fails on Fedora** with `Handshake failed: signature verification failed`. The TV only offers the `ssh-rsa` host-key algorithm (SHA-1 signatures), and Fedora's crypto policy disables SHA-1 in OpenSSL. Fix it per command with `OPENSSL_ENABLE_SHA1_SIGNATURES=1`; the system policy can stay as it is.
- The key fetched by `ares-novacom --getkey` is encrypted, so the Developer Mode passphrase also has to go in the device config (`ares-setup-device -m lgtv -i passphrase=…`).
- **Moonlight shows "Can't find a writable directory to save settings".** Moonlight uses `$HOME/conf`, and `$HOME` is the app install dir (`/media/developer/apps/usr/palm/applications/com.limelight.webos`). That dir is `root:root 775`, while the app runs as an unprivileged uid (6624, gid 5000), so it falls back to `/tmp/moonlight-tv/conf` and the pairing is lost at power-off. Fix: ship `conf/` and `cache/` as mode-777 dirs inside the ipk (`scripts/repack-moonlight-ipk.sh`). The installer keeps the modes.
- Moonlight's decoder options on this TV are *webOS NDL*, *NetCast legacy* and *webOS SMP*. Auto picked NDL. **SMP felt like less lag** in practice. HEVC, AV1 and HDR aren't available.

### Sunshine on a hybrid-GPU KDE Wayland laptop

Out of the box, Sunshine fell back to **software x264**:
- **NVENC** failed with `Couldn't find monitor [0]`. KMS capture was tried on the NVIDIA card, but the internal panel (`eDP-1`) is driven by the AMD iGPU.
- **VA-API (AMD)** failed with `No usable encoding profile found`. Fedora's Mesa build has H.264/HEVC encode disabled for patent reasons; `mesa-va-drivers-freeworld` from RPM Fusion would enable it.

The fix was `capture = kwin` (KWin ScreenCast over PipeWire, with no permission prompt thanks to the bundled KWin desktop permission file) plus `encoder = nvenc`. Sunshine then picks `h264_nvenc` and `hevc_nvenc`.

Pairing from the CLI: newer Sunshine builds need the request's `pairing_id` in `POST /api/pin`. Get it from `GET /api/pin` (`scripts/sunshine-pair.sh`).

### Result

With Moonlight set to 1080p60, 30 Mbps, H.264 and the SMP decoder, the stream is smooth and sharp, has audio, and lags only slightly. The default bitrate (about 7.3 Mbps) noticeably softened desktop text.

## Open items

- Developer Mode expires after about 50 h. It could be auto-extended from the laptop.
- The TV's IP is assigned by DHCP. Reserve it in the router so the `ares` device config stays valid.

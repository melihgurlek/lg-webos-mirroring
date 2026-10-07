# browser-mirror (archived)

Mirrors a Wayland desktop to an LG webOS TV's **built-in browser**, with no Developer Mode needed. It was superseded by Sunshine + Moonlight TV (see the top-level README). The reasons are in [FINDINGS.md](../../FINDINGS.md#2-attempt-1-stream-to-the-tvs-built-in-browser-archived).

How it works: xdg-desktop-portal ScreenCast feeds PipeWire, GStreamer `nvh264enc` encodes all-intra at constant QP, ffmpeg remuxes to fMP4 with one fragment per frame, a WebSocket carries it to the TV, and MSE plays it in Chromium 38.

```sh
python3 -m venv --system-site-packages .venv   # needs system PyGObject + GStreamer
.venv/bin/pip install aiowebostv               # also pulls in aiohttp
.venv/bin/python tvmirror.py --tv <TV_IP>      # accept the pairing prompt on the TV the first time
```

Live tuning while it runs: `curl 'http://localhost:8765/set?qp=24&fps=30'`. Player tuning goes in the page URL: `?target=0.5&max=1.5&rate=1.05`.

Known issues: about 0.5–1 s of lag, occasional stalls from variable-frame-rate duration gaps, and no audio.

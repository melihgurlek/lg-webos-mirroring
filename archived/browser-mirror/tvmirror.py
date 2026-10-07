#!/usr/bin/env python3
"""Mirror this (KDE/GNOME Wayland) desktop to an LG webOS TV over the LAN.

Pipeline:
  xdg-desktop-portal ScreenCast -> PipeWire -> GStreamer (H.264 encode)
  -> ffmpeg (remux to fragmented MP4) -> WebSocket -> TV browser (Media Source Extensions)

The TV's built-in browser is opened on the stream page via the webOS SSAP API.
"""
import argparse
import asyncio
import os
import secrets
import signal
import socket
import struct
import subprocess
import sys
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstVideo", "1.0")
from gi.repository import Gio, GLib, Gst, GstVideo  # noqa: E402

from aiohttp import WSMsgType, web  # noqa: E402

from fmp4 import normalize_fragment, parse_trex_defaults  # noqa: E402

HERE = Path(__file__).resolve().parent
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "tvmirror"


# --------------------------------------------------------------------------- portal

class ScreenCastPortal:
    """Minimal synchronous client for org.freedesktop.portal.ScreenCast."""

    DEST = "org.freedesktop.portal.Desktop"
    PATH = "/org/freedesktop/portal/desktop"
    IFACE = "org.freedesktop.portal.ScreenCast"

    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION)
        self.sender = self.bus.get_unique_name()[1:].replace(".", "_")
        self.session = None

    def _request(self, method, params, options_index):
        token = "tvmirror_" + secrets.token_hex(4)
        req_path = f"/org/freedesktop/portal/desktop/request/{self.sender}/{token}"
        loop = GLib.MainLoop()
        result = {}

        def on_response(_conn, _sender, _path, _iface, _sig, args):
            result["code"], result["results"] = args.unpack()
            loop.quit()

        sub = self.bus.signal_subscribe(
            self.DEST, "org.freedesktop.portal.Request", "Response", req_path,
            None, Gio.DBusSignalFlags.NO_MATCH_RULE, on_response)
        params = list(params)
        params[options_index]["handle_token"] = GLib.Variant("s", token)
        sig = {"CreateSession": "(a{sv})", "SelectSources": "(oa{sv})", "Start": "(osa{sv})"}[method]
        self.bus.call_sync(self.DEST, self.PATH, self.IFACE, method,
                           GLib.Variant(sig, tuple(params)), None, Gio.DBusCallFlags.NONE, -1, None)
        loop.run()
        self.bus.signal_unsubscribe(sub)
        if result["code"] != 0:
            raise RuntimeError(f"Screen sharing was cancelled or denied ({method}, code {result['code']})")
        return result["results"]

    def start(self, restore_token=None):
        res = self._request("CreateSession", [{
            "session_handle_token": GLib.Variant("s", "tvmirror_s" + secrets.token_hex(4)),
        }], 0)
        self.session = res["session_handle"]

        opts = {
            "types": GLib.Variant("u", 1),          # monitors
            "multiple": GLib.Variant("b", False),
            "cursor_mode": GLib.Variant("u", 2),    # cursor embedded in the video
            "persist_mode": GLib.Variant("u", 2),   # remember the choice until revoked
        }
        if restore_token:
            opts["restore_token"] = GLib.Variant("s", restore_token)
        self._request("SelectSources", [self.session, opts], 1)

        res = self._request("Start", [self.session, "", {}], 2)
        node_id = res["streams"][0][0]
        new_token = res.get("restore_token")

        reply, fds = self.bus.call_with_unix_fd_list_sync(
            self.DEST, self.PATH, self.IFACE, "OpenPipeWireRemote",
            GLib.Variant("(oa{sv})", (self.session, {})), None,
            Gio.DBusCallFlags.NONE, -1, None, None)
        fd = fds.get(reply.unpack()[0])
        return fd, node_id, new_token


# --------------------------------------------------------------------------- capture/encode

def build_pipeline(pw_fd, node_id, out_fd, args):
    if args.encoder == "nvenc":
        # Constant QP: screen text stays sharp, and still screens cost almost nothing.
        enc = (f"nvh264enc name=enc preset=p4 tune=ultra-low-latency zerolatency=true bframes=0 "
               f"rc-mode=constqp qp-const-i={args.qp} gop-size=1 repeat-sequence-header=true")
    else:
        enc = (f"openh264enc name=enc complexity=low rate-control=bitrate bitrate={args.bitrate * 1000} "
               f"gop-size=1")
    desc = (
        f"pipewiresrc fd={pw_fd} path={node_id} do-timestamp=true keepalive-time=200 always-copy=true "
        f"! videorate name=rate drop-only=true max-rate={args.fps} "
        f"! videoconvert ! videoscale "
        f"! video/x-raw,width={args.width},height={args.height},pixel-aspect-ratio=1/1 "
        f"! queue max-size-buffers=2 leaky=downstream "
        f"! {enc} "
        f"! video/x-h264,stream-format=byte-stream,profile=high "
        f"! h264parse config-interval=-1 "
        f"! fdsink name=sink fd={out_fd} sync=false"
    )
    return Gst.parse_launch(desc)


def start_muxer(stdin_fd):
    """ffmpeg: raw H.264 in, fragmented MP4 (one fragment per frame) out."""
    return subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error",
         "-fflags", "nobuffer", "-use_wallclock_as_timestamps", "1",
         "-probesize", "200000", "-analyzeduration", "0",
         "-f", "h264", "-i", "pipe:0",
         "-c", "copy", "-f", "mp4",
         "-movflags", "empty_moov+default_base_moof+frag_every_frame+skip_trailer",
         "pipe:1"],
        stdin=stdin_fd, stdout=subprocess.PIPE, pass_fds=())


# --------------------------------------------------------------------------- fMP4

def codec_string(init):
    i = init.find(b"avcC")
    if i < 0:
        return "avc1.640028"
    return "avc1.%02X%02X%02X" % (init[i + 5], init[i + 6], init[i + 7])


# --------------------------------------------------------------------------- streaming server

class Client:
    def __init__(self):
        self.queue = asyncio.Queue(maxsize=90)
        self.wait_key = True
        self.bytes_sent = 0
        self.frames_sent = 0
        self.drops = 0


class Broadcaster:
    def __init__(self, pipeline):
        self.pipeline = pipeline
        self.init = None
        self.codec = None
        self.ready = asyncio.Event()
        self.clients = set()

    def close_all(self):
        for c in self.clients:
            while not c.queue.empty():
                c.queue.get_nowait()
            c.queue.put_nowait(None)

    def request_keyframe(self):
        # Deliver the upstream event straight to the encoder's src pad from a worker thread,
        # so it never waits on the (possibly blocked) sink's streaming lock.
        def send():
            evt = GstVideo.video_event_new_upstream_force_key_unit(Gst.CLOCK_TIME_NONE, True, 0)
            self.pipeline.get_by_name("enc").get_static_pad("src").send_event(evt)
        asyncio.get_running_loop().run_in_executor(None, send)

    async def read_muxer(self, stream):
        pending = b""
        while True:
            hdr = await stream.readexactly(8)
            size, kind = struct.unpack(">I4s", hdr)
            if size == 1:
                ext = await stream.readexactly(8)
                hdr += ext
                size = struct.unpack(">Q", ext)[0]
            box = hdr + await stream.readexactly(size - len(hdr))
            if kind in (b"ftyp", b"moov"):
                pending += box
                if kind == b"moov":
                    self.init, pending = pending, b""
                    self.codec = codec_string(self.init)
                    self.trex = parse_trex_defaults(self.init)
                    self.ready.set()
                    print(f"stream ready ({self.codec})", flush=True)
            elif kind == b"moof":
                pending = box
            elif kind == b"mdat":
                frag, key = normalize_fragment(pending + box, self.trex, mark_sync=True)
                pending = b""
                self.publish(frag, key)

    def publish(self, frag, key):
        for c in list(self.clients):
            if c.wait_key and not key:
                continue
            c.wait_key = False
            q = c.queue
            if q.full():  # client fell behind: drop everything and resync on next keyframe
                c.drops += 1
                while not q.empty():
                    q.get_nowait()
                c.wait_key = True
                self.request_keyframe()
                continue
            q.put_nowait(frag)

    async def stats_loop(self, every=3.0):
        prev = {}
        while True:
            await asyncio.sleep(every)
            for c in list(self.clients):
                b0, f0 = prev.get(id(c), (0, 0))
                print(f"server: {(c.bytes_sent - b0) * 8 / every / 1e6:.1f} Mbit/s "
                      f"{(c.frames_sent - f0) / every:.0f} fps queue={c.queue.qsize()} drops={c.drops}",
                      flush=True)
                prev[id(c)] = (c.bytes_sent, c.frames_sent)

    async def set_handler(self, request):
        """Live tuning: /set?qp=24&fps=20"""
        enc = self.pipeline.get_by_name("enc")
        rate = self.pipeline.get_by_name("rate")
        if "qp" in request.query and enc.find_property("qp-const-i"):
            enc.set_property("qp-const-i", int(request.query["qp"]))
        if "fps" in request.query:
            rate.set_property("max-rate", int(request.query["fps"]))
        msg = f"qp={enc.get_property('qp-const-i') if enc.find_property('qp-const-i') else '-'} fps={rate.get_property('max-rate')}"
        print("set " + msg, flush=True)
        return web.Response(text=msg + "\n")

    async def ws_handler(self, request):
        ws = web.WebSocketResponse(heartbeat=10)
        await ws.prepare(request)
        await self.ready.wait()
        client = Client()
        await ws.send_str(self.codec)
        await ws.send_bytes(self.init)
        self.clients.add(client)
        self.request_keyframe()
        print(f"viewer connected: {request.remote}", flush=True)

        async def drain_incoming():
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    print(f"viewer {request.remote}: {msg.data}", flush=True)

        reader = asyncio.create_task(drain_incoming())
        try:
            while not ws.closed:
                frag = await client.queue.get()
                if frag is None:  # shutting down
                    await ws.close()
                    break
                await ws.send_bytes(frag)
                client.bytes_sent += len(frag)
                client.frames_sent += 1
        except (ConnectionResetError, RuntimeError):
            pass
        finally:
            reader.cancel()
            self.clients.discard(client)
            print(f"viewer disconnected: {request.remote}", flush=True)
        return ws


async def open_on_tv(tv_ip, key_file, url):
    from aiowebostv import WebOsClient
    key = key_file.read_text().strip() if key_file.exists() else None
    if not key:
        print("Pairing with the TV - accept the prompt on the TV screen...", flush=True)
    client = WebOsClient(tv_ip, client_key=key, connect_timeout=90)
    await client.connect()
    key_file.parent.mkdir(parents=True, exist_ok=True)
    key_file.write_text(client.client_key)
    await client.request("system.launcher/open", {"target": url})
    await client.disconnect()


def local_ip_for(target):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((target, 9))
        return s.getsockname()[0]
    finally:
        s.close()


async def main(args):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    token_file = STATE_DIR / "restore_token"

    print("Requesting screen capture (choose the screen in the dialog if asked)...", flush=True)
    portal = ScreenCastPortal()
    old_token = token_file.read_text().strip() if token_file.exists() else None
    pw_fd, node_id, new_token = portal.start(old_token)
    if new_token:
        token_file.write_text(new_token)

    r, w = os.pipe()
    muxer = start_muxer(r)
    os.close(r)
    pipeline = build_pipeline(pw_fd, node_id, w, args)

    loop = asyncio.get_running_loop()
    caster = Broadcaster(pipeline)
    muxer_out = asyncio.StreamReader(limit=2**24)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(muxer_out), muxer.stdout)

    if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
        sys.exit("GStreamer pipeline failed to start (try --encoder openh264)")

    def watch_bus():
        bus = pipeline.get_bus()
        while not stop.is_set():
            msg = bus.timed_pop_filtered(Gst.SECOND, Gst.MessageType.ERROR | Gst.MessageType.EOS)
            if msg:
                if msg.type == Gst.MessageType.ERROR:
                    err, dbg = msg.parse_error()
                    print(f"GStreamer error: {err.message}\n{dbg}", file=sys.stderr, flush=True)
                else:
                    print("capture ended", flush=True)
                loop.call_soon_threadsafe(stop.set)
                return
    stop = asyncio.Event()
    watcher = loop.run_in_executor(None, watch_bus)
    reader_task = asyncio.create_task(caster.read_muxer(muxer_out))
    reader_task.add_done_callback(lambda t: stop.set())

    app = web.Application()
    app.router.add_get("/", lambda _: web.FileResponse(HERE / "static/index.html",
                                                        headers={"Cache-Control": "no-store"}))
    app.router.add_get("/ws", caster.ws_handler)
    app.router.add_get("/set", caster.set_handler)
    stats_task = asyncio.create_task(caster.stats_loop())
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "0.0.0.0", args.port).start()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    if args.tv:
        url = f"http://{local_ip_for(args.tv)}:{args.port}/"
        print(f"Serving on {url}", flush=True)
        if not args.no_launch:
            await asyncio.wait_for(caster.ready.wait(), 15)
            await open_on_tv(args.tv, STATE_DIR / "tv_client_key", url)
            print("Opened the stream on the TV. Ctrl+C to stop.", flush=True)
    else:
        print(f"Serving on port {args.port}. Ctrl+C to stop.", flush=True)

    await stop.wait()
    print("stopping...", flush=True)
    # Kill the muxer first: otherwise fdsink can be blocked writing into a full pipe that
    # nobody drains, and setting the pipeline to NULL would wait on it forever.
    muxer.kill()
    reader_task.cancel()
    await loop.run_in_executor(None, pipeline.set_state, Gst.State.NULL)
    os.close(w)
    await watcher
    stats_task.cancel()
    caster.close_all()
    await runner.cleanup()


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--tv", required=True, help="TV IP address")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--fps", type=int, default=30)
    # Every frame is a keyframe (LG's browser can't display inter frames from per-frame
    # fragments), so this needs far more bitrate than normal H.264 streaming.
    p.add_argument("--qp", type=int, default=22,
                   help="nvenc quality, lower = sharper/bigger (default: %(default)s, ~35 Mbit/s at full motion)")
    p.add_argument("--bitrate", type=int, default=40000, help="openh264 only, kbit/s (default: %(default)s)")
    p.add_argument("--width", type=int, default=1920)
    p.add_argument("--height", type=int, default=1080)
    p.add_argument("--encoder", choices=["nvenc", "openh264"], default="nvenc")
    p.add_argument("--no-launch", action="store_true", help="don't open the browser on the TV")
    Gst.init(None)
    try:
        asyncio.run(main(p.parse_args()))
    except KeyboardInterrupt:
        pass
    except RuntimeError as e:
        sys.exit(str(e))

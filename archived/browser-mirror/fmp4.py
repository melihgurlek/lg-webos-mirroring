"""Fragmented-MP4 helpers.

LG's webOS 3.5 browser (Chromium 38) rejects fragments that rely on tfhd default sample
size/duration/flags (what ffmpeg writes with frag_every_frame). `normalize_fragment`
rewrites each moof so every sample's duration/size/flags are explicit in the trun.
"""
import struct


def iter_boxes(data, start=0, end=None):
    end = len(data) if end is None else end
    i = start
    while i + 8 <= end:
        size, kind = struct.unpack_from(">I4s", data, i)
        hdr = 8
        if size == 1:
            size = struct.unpack_from(">Q", data, i + 8)[0]
            hdr = 16
        elif size == 0:
            size = end - i
        yield kind, i + hdr, i + size
        i += size


def _box(kind, payload):
    return struct.pack(">I4s", 8 + len(payload), kind) + payload


def _full(kind, version, flags, payload):
    return _box(kind, struct.pack(">I", (version << 24) | flags) + payload)


def parse_trex_defaults(init):
    """(duration, size, flags) defaults from moov/mvex/trex."""
    i = init.find(b"trex")
    if i < 0:
        return 0, 0, 0
    return struct.unpack_from(">III", init, i + 4 + 4 + 4 + 4)  # skip type, ver/flags, track, desc idx


def normalize_fragment(frag, trex=(0, 0, 0), mark_sync=False):
    """Rewrite a single-traf moof+mdat so the trun carries explicit per-sample fields.

    mark_sync flags the first sample as a sync sample regardless of its real type: LG's
    browser rejects any media segment whose first sample isn't flagged sync, but it only
    checks the flag, so per-frame fragments play fine once relabelled.

    Returns (new_fragment_bytes, first_sample_was_really_sync).
    """
    (kind, ms, me), (kind2, ds, de) = list(iter_boxes(frag))[:2]
    assert kind == b"moof" and kind2 == b"mdat", (kind, kind2)
    mfhd = traf_s = traf_e = None
    for k, s, e in iter_boxes(frag, ms, me):
        if k == b"mfhd":
            mfhd = frag[s - 8:e]
        elif k == b"traf":
            traf_s, traf_e = s, e

    d_dur, d_size, d_flags = trex
    track_id = 1
    tfdt = None
    samples = []
    for k, s, e in iter_boxes(frag, traf_s, traf_e):
        vf = struct.unpack_from(">I", frag, s)[0]
        version, flags = vf >> 24, vf & 0xFFFFFF
        p = s + 4
        if k == b"tfhd":
            track_id = struct.unpack_from(">I", frag, p)[0]
            p += 4
            if flags & 0x1:
                p += 8
            if flags & 0x2:
                p += 4
            if flags & 0x8:
                d_dur = struct.unpack_from(">I", frag, p)[0]; p += 4
            if flags & 0x10:
                d_size = struct.unpack_from(">I", frag, p)[0]; p += 4
            if flags & 0x20:
                d_flags = struct.unpack_from(">I", frag, p)[0]; p += 4
        elif k == b"tfdt":
            tfdt = frag[s - 8:e]
        elif k == b"trun":
            count = struct.unpack_from(">I", frag, p)[0]; p += 4
            if flags & 0x1:
                p += 4
            first_flags = None
            if flags & 0x4:
                first_flags = struct.unpack_from(">I", frag, p)[0]; p += 4
            for n in range(count):
                dur, size, sflags, cto = d_dur, d_size, d_flags, 0
                if flags & 0x100:
                    dur = struct.unpack_from(">I", frag, p)[0]; p += 4
                if flags & 0x200:
                    size = struct.unpack_from(">I", frag, p)[0]; p += 4
                if flags & 0x400:
                    sflags = struct.unpack_from(">I", frag, p)[0]; p += 4
                if flags & 0x800:
                    cto = struct.unpack_from(">i" if version else ">I", frag, p)[0]; p += 4
                if n == 0 and first_flags is not None:
                    sflags = first_flags
                samples.append((dur, size, sflags, cto))

    if samples and samples[0][0] == 0:
        # A zero duration (e.g. ffmpeg's last-known-duration unknown) would stall playback.
        samples[0] = (d_dur or 1,) + samples[0][1:]

    sync = not (samples[0][2] & 0x10000) if samples else True
    if mark_sync and samples:
        samples[0] = samples[0][:2] + (0x02000000,) + samples[0][3:]  # depends_on=2 (I-frame)

    has_cto = any(s[3] for s in samples)
    trun_flags = 0x1 | 0x100 | 0x200 | 0x400 | (0x800 if has_cto else 0)
    tfhd = _full(b"tfhd", 0, 0x020000, struct.pack(">I", track_id))  # default-base-is-moof

    def build(data_offset):
        body = struct.pack(">Ii", len(samples), data_offset)
        for dur, size, sflags, cto in samples:
            body += struct.pack(">III", dur, size, sflags)
            if has_cto:
                body += struct.pack(">i", cto)
        trun = _full(b"trun", 1 if has_cto else 0, trun_flags, body)
        traf = _box(b"traf", tfhd + (tfdt or b"") + trun)
        return _box(b"moof", mfhd + traf)

    moof = build(0)
    moof = build(len(moof) + 8)
    mdat = frag[ds - 8:de]
    if de - ds + 8 != len(mdat) or frag[ds - 8 + 4:ds] != b"mdat" or struct.unpack_from(">I", frag, ds - 8)[0] == 1:
        mdat = _box(b"mdat", frag[ds:de])  # re-emit with a plain 32-bit header
    return moof + mdat, sync

#!/usr/bin/env python3
"""Rebuild the brand image assets in `Assets.xcassets` from the artwork export.

    ./run.sh [path/to/art.png]

The artwork arrives from the design tool as a flat RGB PNG: the transparency checkerboard (10px
cells of #CCCCCC / #FFFFFF) is baked into the pixels and there is **no alpha channel**, so it
cannot be dropped into an asset catalogue as-is — a splash would show the checkerboard and an app
icon would show grey squares. `LotLizard - Splash - Transparent.png` is the source; the script does
not care what the file is called, only that it has that layout.

What this does, in order:

  1. **Classifies** the checkerboard (neutral and light — no ink is neutral *and* that light).
  2. **Flood fills** it in from the border, so light ink *inside* the art — the mark's eye, the gaps
     between its legs, the counters of the wordmark — is never mistaken for background.
  3. **Un-mixes** the one-pixel antialiased rim against its local background, so the art does not
     carry a grey halo on a coloured page.
  4. **Splits** the art into the three files the catalogue wants: `SplashArt` (trimmed of the
     export's empty margin, at 1x and 2x, light and dark), `AppMark` (the lizard alone, three
     scales, for the titlebar) and `AppIcon` (the mark on the macOS icon grid, ten sizes).

The dark appearance of `SplashArt` is the same art with its two lines of type re-inked light: the
name and tagline are dark ink, which would vanish on a dark page, while the mark's own greens read
on either.

Only the icon's upscales go through `sips`, which resamples a flat mark more smoothly than
anything worth hand-rolling here; every other pixel is scaled in premultiplied alpha below, so no
transparent pixel can bleed its (meaningless) colour into an edge.
"""
import json
import os
import struct
import subprocess
import sys
import zlib
from collections import deque

DEFAULT_SOURCE = os.path.expanduser("~/Downloads/LotLizard - Splash - Transparent.png")
ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "..", "PalletAuctionBidTool", "Assets.xcassets")
ASSETS = os.path.normpath(ASSETS)

# The width the splash draws its art at, in points — `Theme.splashArtWidth`. Both scale files are
# generated at this size, so the window shows the art at native pixels instead of resampling it.
SPLASH_WIDTH = 320
# Row bands of the source layout (measured): the mark, then the wordmark and tagline under it.
MARK_BAND = (84, 281)
# Where the two lines of type start, as a fraction of the art's own ink height: the blank gap
# between the mark's tail (row 281) and the wordmark's cap (row 306) spans 0.66 … 0.75 of it.
TEXT_TOP_FROM_INK = 0.70
# The mark's share of an icon's canvas on the macOS icon grid: the art is drawn into the middle
# four fifths of the square, which is where macOS expects an app's artwork to sit.
ICON_MARGIN = 0.30
# Sizes the icon set is built at, and the file each `Contents.json` entry names.
ICON_SIZES = (16, 32, 64, 128, 256, 512, 1024)


# ------------------------------------------------------------------ png io ----

def load_png(path):
    """Decode an 8-bit RGB or RGBA PNG. Returns (width, height, channels, pixels, colortype)."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    i, idat = 8, b""
    w = h = ct = bd = 0
    while i < len(data):
        length = struct.unpack_from(">I", data, i)[0]
        kind = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + length]
        if kind == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        i += 12 + length
    if bd != 8 or ct not in (2, 6):
        raise SystemExit(f"{path}: expected an 8-bit RGB or RGBA PNG "
                         f"(got bit depth {bd}, colour type {ct})")
    channels = {2: 3, 6: 4}[ct]
    raw = zlib.decompress(idat)
    stride = w * channels
    out = bytearray(stride * h)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        filt = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if filt == 1:
            for x in range(channels, stride):
                line[x] = (line[x] + line[x - channels]) & 255
        elif filt == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif filt == 3:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif filt == 4:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                b, c = prev[x], prev[x - channels] if x >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, channels, out, ct


def write_png(path, w, h, rgba):
    """Write an 8-bit RGBA PNG, each scanline unfiltered."""
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    blob = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(blob)
    return path


# -------------------------------------------------------------- geometry ----

def resize(rgba, w, h, tw, th):
    """Box-filter resize, averaging in premultiplied space so clear pixels add no colour."""
    out = bytearray(tw * th * 4)
    for ty in range(th):
        y0 = ty * h // th
        y1 = max(y0 + 1, (ty + 1) * h // th)
        for tx in range(tw):
            x0 = tx * w // tw
            x1 = max(x0 + 1, (tx + 1) * w // tw)
            rs = gs = bs = asum = n = 0
            for y in range(y0, y1):
                base = y * w * 4
                for x in range(x0, x1):
                    i = base + x * 4
                    a = rgba[i + 3]
                    rs += rgba[i] * a
                    gs += rgba[i + 1] * a
                    bs += rgba[i + 2] * a
                    asum += a
                    n += 1
            o = (ty * tw + tx) * 4
            if asum:
                out[o] = min(255, rs // asum)
                out[o + 1] = min(255, gs // asum)
                out[o + 2] = min(255, bs // asum)
            out[o + 3] = asum // max(1, n)
    return out


def paste(canvas, cw, ch, src, sw, sh, x0, y0):
    """Source-over paste of one RGBA sprite into another."""
    for y in range(sh):
        ty = y0 + y
        if not 0 <= ty < ch:
            continue
        for x in range(sw):
            tx = x0 + x
            if not 0 <= tx < cw:
                continue
            si = (y * sw + x) * 4
            a = src[si + 3]
            if not a:
                continue
            di = (ty * cw + tx) * 4
            da = canvas[di + 3]
            na = a + da * (255 - a) // 255
            for c in range(3):
                canvas[di + c] = (src[si + c] * a
                                  + canvas[di + c] * da * (255 - a) // 255) // max(1, na)
            canvas[di + 3] = na


def crop(rgba, w, x0, y0, cw, chh):
    out = bytearray(cw * chh * 4)
    for y in range(chh):
        s = ((y0 + y) * w + x0) * 4
        d = y * cw * 4
        out[d:d + cw * 4] = rgba[s:s + cw * 4]
    return out


def pad(rgba, w, h, margin):
    """Grow a sprite's canvas by `margin` of its long edge, keeping the art centred."""
    cw = int(w * (1 + margin) + 0.5)
    chh = int(h * (1 + margin) + 0.5)
    canvas = bytearray(cw * chh * 4)
    for y in range(h):
        s = y * w * 4
        d = ((y + (chh - h) // 2) * cw + (cw - w) // 2) * 4
        canvas[d:d + w * 4] = rgba[s:s + w * 4]
    return canvas, cw, chh


def square(rgba, w, h, margin):
    """Centre a sprite in a transparent square, `margin` a fraction of its long edge."""
    side = int(max(w, h) * (1 + margin) + 0.5)
    canvas = bytearray(side * side * 4)
    paste(canvas, side, side, rgba, w, h, (side - w) // 2, (side - h) // 2)
    return canvas, side


# ---------------------------------------------------------------- the art ----

class Art:
    """The source export, plus the matte rebuilt from it."""

    def __init__(self, path):
        self.path = path
        w, h, channels, pixels, colortype = load_png(path)
        self.w, self.h, self.ch, self.ct, self.px = w, h, channels, colortype, pixels

    def rgb(self, x, y):
        i = (y * self.w + x) * self.ch
        p = self.px
        return p[i], p[i + 1], p[i + 2]

    def bgish(self, x, y):
        """True where a pixel can only be the export's checkerboard: neutral *and* light."""
        r, g, b = self.rgb(x, y)
        sat = max(r, g, b) - min(r, g, b)
        lum = (299 * r + 587 * g + 114 * b) // 1000
        return sat <= 14 and lum >= 176

    def exterior(self):
        """Flood fill the checkerboard in from the border, four-connectedly."""
        w, h = self.w, self.h
        ext = bytearray(w * h)
        queue = deque()
        edge = ([(x, 0) for x in range(w)] + [(x, h - 1) for x in range(w)]
                + [(0, y) for y in range(h)] + [(w - 1, y) for y in range(h)])
        for x, y in edge:
            i = y * w + x
            if not ext[i] and self.bgish(x, y):
                ext[i] = 1
                queue.append((x, y))
        while queue:
            x, y = queue.popleft()
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if 0 <= nx < w and 0 <= ny < h:
                    i = ny * w + nx
                    if not ext[i] and self.bgish(nx, ny):
                        ext[i] = 1
                        queue.append((nx, ny))
        return ext

    def matte(self):
        """RGBA with a real alpha channel: clear outside, opaque inside, un-mixed 1px rim."""
        w, h = self.w, self.h
        ext = self.exterior()
        out = bytearray(w * h * 4)
        neighbours = ((-1, 0), (1, 0), (0, -1), (0, 1),
                      (-1, -1), (1, -1), (-1, 1), (1, 1))
        for y in range(h):
            for x in range(w):
                i = y * w + x
                if ext[i]:
                    continue
                r, g, b = self.rgb(x, y)
                bg = None
                bgn = 0
                ink = None
                inkdist = -1
                for dx, dy in neighbours:
                    nx, ny = x + dx, y + dy
                    if not (0 <= nx < w and 0 <= ny < h):
                        continue
                    colour = self.rgb(nx, ny)
                    if ext[ny * w + nx]:
                        bg = colour if bg is None else tuple(
                            (bg[k] * bgn + colour[k]) // (bgn + 1) for k in range(3))
                        bgn += 1
                    elif bg is not None:
                        d = max(abs(colour[k] - bg[k]) for k in range(3))
                        if d > inkdist:
                            inkdist, ink = d, colour
                if bg is None:
                    colour, alpha = (r, g, b), 255
                else:
                    if inkdist > 40:
                        alpha = max(abs(r - bg[0]), abs(g - bg[1]), abs(b - bg[2])) * 255 // inkdist
                    else:
                        # No ink worth reading beside it: assume dark ink on light paper.
                        lum = (299 * r + 587 * g + 114 * b) // 1000
                        bgl = (299 * bg[0] + 587 * bg[1] + 114 * bg[2]) // 1000
                        alpha = (bgl - lum) * 255 // max(1, bgl - 32)
                    alpha = max(0, min(255, alpha))
                    if not alpha:
                        continue
                    # Un-mix the blend p = alpha*F + (1-alpha)*bg for the ink colour F.
                    colour = tuple(max(0, min(255, (pv * 255 - (255 - alpha) * bgv) // alpha))
                                   for pv, bgv in zip((r, g, b), bg))
                o = i * 4
                out[o], out[o + 1], out[o + 2] = colour
                out[o + 3] = alpha
        return out, ext


def lighten_text(rgba, w, h, top, amount=0.74):
    """Lift ink below `top` toward white — the dark-appearance splash's two lines of type."""
    out = bytearray(rgba)
    for y in range(top, h):
        for x in range(w):
            i = (y * w + x) * 4
            if not out[i + 3]:
                continue
            for c in range(3):
                out[i + c] = int(out[i + c] + (255 - out[i + c]) * amount)
    return out


def bbox(ext, w, y0, y1):
    """Bounding box of everything that is not background, within rows `y0 … y1`."""
    pts = [(x, y) for y in range(y0, y1 + 1) for x in range(w) if not ext[y * w + x]]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


# ------------------------------------------------------------ the catalogue ----

def imageset(files):
    """An `imageset`'s `Contents.json`, from `(file, scale, appearance)` triples."""
    entries = []
    for filename, scale, appearance in files:
        entry = {}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        entry.update({"filename": filename, "idiom": "universal", "scale": scale})
        entries.append(entry)
    return write_json(entries)


def appiconset(files):
    """The `appiconset`'s `Contents.json`: macOS wants the ten `mac` entries, not one 1024."""
    entries = []
    for filename, size, scale in files:
        entries.append({"filename": filename, "idiom": "mac", "scale": scale,
                        "size": f"{size}x{size}"})
    return write_json(entries)


def write_json(images):
    """`Contents.json` for the entries above — plain JSON, which is all actool reads."""
    return json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                      indent=2, sort_keys=True) + "\n"


def sips(source, size, destination):
    """Resample a PNG with `sips`, which smooths a flat mark better than a box filter upscales."""
    subprocess.run(["sips", "-z", str(size), str(size), source, "--out", destination],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ------------------------------------------------------------------- main ----

def main():
    source = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SOURCE
    if not os.path.exists(source):
        raise SystemExit(f"no artwork at {source}\n"
                         f"pass one: ./run.sh path/to/art.png")
    print(f"source: {source}")
    art = Art(source)
    rgba, ext = art.matte()
    w, h = art.w, art.h
    print(f"  {w}x{h} {art.ct == 6 and 'RGBA' or 'RGB'} -> matte built")

    # -- SplashArt: trimmed of the export's empty margin, at the size it is drawn ---
    ix0, iy0, ix1, iy1 = bbox(ext, w, 0, h - 1)
    print(f"  ink bbox x {ix0}-{ix1}  y {iy0}-{iy1} (export margin trimmed)")
    trimmed, tw, th = pad(crop(rgba, w, ix0, iy0, ix1 - ix0 + 1, iy1 - iy0 + 1),
                          ix1 - ix0 + 1, iy1 - iy0 + 1, 0.08)
    splash = os.path.join(ASSETS, "SplashArt.imageset")
    os.makedirs(splash, exist_ok=True)
    scale_files = []
    for scale in (1, 2):
        dw = SPLASH_WIDTH * scale
        dh = max(1, round(th * dw / tw))
        light = resize(trimmed, tw, th, dw, dh)
        write_png(os.path.join(splash, f"splash-art-{scale}x.png"), dw, dh, light)
        dark = lighten_text(light, dw, dh, round(TEXT_TOP_FROM_INK * dh))
        write_png(os.path.join(splash, f"splash-art-dark-{scale}x.png"), dw, dh, dark)
        scale_files += [(f"splash-art-{scale}x.png", f"{scale}x", None),
                        (f"splash-art-dark-{scale}x.png", f"{scale}x", "dark")]
        print(f"  splash-art {dw}x{dh} (light + dark) @{scale}x")
    with open(os.path.join(splash, "Contents.json"), "w") as fh:
        fh.write(imageset(scale_files))

    # -- AppMark: the lizard alone, tight, for the titlebar ------------------------
    mx0, my0, mx1, my1 = bbox(ext, w, *MARK_BAND)
    mark = crop(rgba, w, mx0, my0, mx1 - mx0 + 1, my1 - my0 + 1)
    mw, mh = mx1 - mx0 + 1, my1 - my0 + 1
    tight, side = square(mark, mw, mh, 0.06)
    marks = os.path.join(ASSETS, "AppMark.imageset")
    os.makedirs(marks, exist_ok=True)
    for scale, px in ((1, 20), (2, 40), (3, 60)):
        art_px = tight if side == px else resize(tight, side, side, px, px)
        write_png(os.path.join(marks, f"app-mark-{scale}x.png"), px, px, art_px)
    with open(os.path.join(marks, "Contents.json"), "w") as fh:
        fh.write(imageset([(f"app-mark-{s}x.png", f"{s}x", None) for s in (1, 2, 3)]))
    print(f"  app-mark {side}px mark -> 20/40/60pt")

    # -- AppIcon: the mark on the macOS icon grid ----------------------------------
    canvas, canvas_side = square(mark, mw, mh, ICON_MARGIN)
    staging = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon-source.png")
    write_png(staging, canvas_side, canvas_side, canvas)
    icons = os.path.join(ASSETS, "AppIcon.appiconset")
    os.makedirs(icons, exist_ok=True)
    biggest = max(ICON_SIZES)
    for size in ICON_SIZES:
        destination = os.path.join(icons, f"AppIcon-{size}.png")
        if size == biggest:
            sips(staging, size, destination)
        else:
            sips(os.path.join(icons, f"AppIcon-{biggest}.png"), size, destination)
    entries = [("AppIcon-16.png", 16, "1x"), ("AppIcon-32.png", 16, "2x"),
               ("AppIcon-32.png", 32, "1x"), ("AppIcon-64.png", 32, "2x"),
               ("AppIcon-128.png", 128, "1x"), ("AppIcon-256.png", 128, "2x"),
               ("AppIcon-256.png", 256, "1x"), ("AppIcon-512.png", 256, "2x"),
               ("AppIcon-512.png", 512, "1x"), ("AppIcon-1024.png", 512, "2x")]
    with open(os.path.join(icons, "Contents.json"), "w") as fh:
        fh.write(appiconset(entries))
    print(f"  app icon {canvas_side}px mark on a {biggest}px grid -> "
          f"{'/'.join(str(s) for s in ICON_SIZES)}")
    os.remove(staging)
    print("done")


if __name__ == "__main__":
    main()

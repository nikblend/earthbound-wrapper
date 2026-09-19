#!/usr/bin/env python3
"""Generate the app icon and asset catalog.

Written as plain Python with only the standard library, on purpose: an app icon
generated at build time keeps a binary out of the repository, and adding Pillow as
a build dependency to draw four circles would be a poor trade.

Two design decisions are worth stating because they are what make the icon look
like something rather than like a placeholder:

  * It is rendered at 2x and box-downsampled. At icon sizes the difference between
    alias-free circles and stair-stepped ones is the entire difference between
    "an app" and "a test harness".
  * The palette is the Super Famicom controller's: red, yellow, blue and green
    face buttons, because that is the thing the icon is a picture of.

Usage:  scripts/make-assets.py [output-directory]
"""

from __future__ import annotations

import json
import math
import os
import struct
import sys
import zlib

SUPERSAMPLE = 2
SIZE = 1024

BACKGROUND_TOP = (0x14, 0x18, 0x27)
BACKGROUND_BOTTOM = (0x23, 0x2B, 0x42)
BEZEL = (0x0B, 0x0E, 0x17)
SCREEN = (0x2E, 0x6B, 0xD6)
STICK_RING = (0xE8, 0xEE, 0xFF)
STICK_DOT = (0xE8, 0xEE, 0xFF)
FACE_BUTTONS = (
    (0.0, -1.0, (0xE0, 0x4B, 0x4B)),   # X, top:    red
    (-1.0, 0.0, (0x4B, 0x8C, 0xE0)),   # Y, left:   blue
    (1.0, 0.0, (0xF2, 0xC1, 0x4E)),    # A, right:  yellow
    (0.0, 1.0, (0x57, 0xB4, 0x5A)),    # B, bottom: green
)


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def mix(a, b, t: float):
    t = clamp(t)
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def coverage(distance: float, radius: float) -> float:
    """Antialiased step from 0 to 1 across the last pixel of an edge."""
    return clamp(radius - distance + 0.5)


def rounded_rect_distance(x: float, y: float, half_w: float, half_h: float, radius: float) -> float:
    dx = abs(x) - (half_w - radius)
    dy = abs(y) - (half_h - radius)
    outside = math.hypot(max(dx, 0.0), max(dy, 0.0))
    inside = min(max(dx, dy), 0.0)
    return outside + inside - radius


def render() -> list[list[tuple[int, int, int]]]:
    n = SIZE * SUPERSAMPLE
    centre = n / 2.0
    rows: list[list[tuple[int, int, int]]] = []

    # Geometry, in supersampled pixels relative to the icon's centre.
    bezel_half = n * 0.375
    bezel_radius = n * 0.115
    screen_half_w = bezel_half - n * 0.055
    screen_half_h = screen_half_w * 0.62
    screen_radius = n * 0.030

    stick_centre = (-bezel_half * 0.46, bezel_half * 0.42)
    stick_ring_radius = n * 0.115
    stick_dot_radius = n * 0.046

    face_centre = (bezel_half * 0.46, bezel_half * 0.42)
    face_radius = n * 0.048
    face_spread = n * 0.108

    for py in range(n):
        row: list[tuple[int, int, int]] = []
        y = py + 0.5 - centre
        for px in range(n):
            x = px + 0.5 - centre

            # Background: a soft vertical gradient, darker at the top.
            colour = mix(BACKGROUND_TOP, BACKGROUND_BOTTOM, (y + centre) / n)

            # Bezel.
            bezel = coverage(rounded_rect_distance(x, y, bezel_half, bezel_half, bezel_radius), 0.0)
            colour = mix(colour, BEZEL, bezel)

            # Screen, inset inside the bezel.
            screen = coverage(rounded_rect_distance(x, y, screen_half_w, screen_half_h,
                                                    screen_radius), 0.0)
            colour = mix(colour, SCREEN, screen)

            # Stick: a ring with a dot in the middle, bottom-left.
            stick_distance = math.hypot(x - stick_centre[0], y - stick_centre[1])
            ring = coverage(abs(stick_distance - stick_ring_radius), n * 0.014)
            dot = coverage(stick_distance, stick_dot_radius)
            colour = mix(colour, STICK_RING, ring)
            colour = mix(colour, STICK_DOT, dot)

            # Face buttons, top-right, in the SNES diamond.
            for ox, oy, button_colour in FACE_BUTTONS:
                bx = face_centre[0] + ox * face_spread
                by = face_centre[1] + oy * face_spread
                hit = coverage(math.hypot(x - bx, y - by), face_radius)
                colour = mix(colour, button_colour, hit)

            row.append((int(colour[0] + 0.5), int(colour[1] + 0.5), int(colour[2] + 0.5)))
        rows.append(row)

    return rows


def downsample(rows: list[list[tuple[int, int, int]]]) -> list[list[tuple[int, int, int, int]]]:
    """Box filter from the supersampled buffer down to SIZE, adding full alpha."""
    out: list[list[tuple[int, int, int, int]]] = []
    samples = SUPERSAMPLE * SUPERSAMPLE
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            r = g = b = 0
            for sy in range(SUPERSAMPLE):
                source_row = rows[y * SUPERSAMPLE + sy]
                for sx in range(SUPERSAMPLE):
                    pixel = source_row[x * SUPERSAMPLE + sx]
                    r += pixel[0]
                    g += pixel[1]
                    b += pixel[2]
            row.append((r // samples, g // samples, b // samples, 255))
        out.append(row)
    return out


def write_png(path: str, pixels: list[list[tuple[int, int, int, int]]]) -> None:
    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter type 0: none
        for pixel in row:
            raw.extend(pixel)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(png)


def write_json(path: str, payload: dict) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    resources = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Resources")
    catalog = os.path.join(resources, "Assets.xcassets")

    appicon = os.path.join(catalog, "AppIcon.appiconset")
    accent = os.path.join(catalog, "AccentColor.colorset")
    os.makedirs(appicon, exist_ok=True)
    os.makedirs(accent, exist_ok=True)

    write_json(os.path.join(catalog, "Contents.json"),
               {"info": {"author": "xcode", "version": 1}})

    # A single 1024x1024 "universal" icon: one image is all a modern iOS app needs,
    # and iOS derives every other size from it.
    write_json(os.path.join(appicon, "Contents.json"), {
        "images": [
            {"filename": "icon-1024.png", "idiom": "universal",
             "platform": "ios", "size": "1024x1024"}
        ],
        "info": {"author": "xcode", "version": 1},
    })
    write_png(os.path.join(appicon, "icon-1024.png"), downsample(render()))

    write_json(os.path.join(accent, "Contents.json"), {
        "colors": [
            {"idiom": "universal",
             "color": {"color-space": "srgb",
                       "components": {"red": "0x2E", "green": "0x6B",
                                      "blue": "0xD6", "alpha": "1.000"}}}
        ],
        "info": {"author": "xcode", "version": 1},
    })

    print(f"wrote {os.path.relpath(catalog, root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

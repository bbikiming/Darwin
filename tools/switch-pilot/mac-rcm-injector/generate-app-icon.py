#!/usr/bin/env python3
"""Generate a Switch-inspired macOS .iconset without external dependencies."""

from __future__ import annotations

import math
import struct
import sys
import zlib
from pathlib import Path

Color = tuple[int, int, int, int]


def blend(dst: Color, src: Color) -> Color:
    sa = src[3] / 255.0
    da = dst[3] / 255.0
    out_a = sa + da * (1.0 - sa)
    if out_a <= 0:
        return (0, 0, 0, 0)
    r = int((src[0] * sa + dst[0] * da * (1.0 - sa)) / out_a + 0.5)
    g = int((src[1] * sa + dst[1] * da * (1.0 - sa)) / out_a + 0.5)
    b = int((src[2] * sa + dst[2] * da * (1.0 - sa)) / out_a + 0.5)
    a = int(out_a * 255 + 0.5)
    return (r, g, b, a)


def write_png(path: Path, width: int, height: int, pixels: list[Color]) -> None:
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixels[y * width + x])

    def chunk(name: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + name
            + data
            + struct.pack(">I", zlib.crc32(name + data) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(png)


def point_in_rounded_rect(px: float, py: float, x: float, y: float, w: float, h: float, r: float) -> bool:
    cx = min(max(px, x + r), x + w - r)
    cy = min(max(py, y + r), y + h - r)
    return (px - cx) ** 2 + (py - cy) ** 2 <= r**2


def draw_rounded_rect(
    pixels: list[Color],
    size: int,
    x: float,
    y: float,
    w: float,
    h: float,
    r: float,
    color: Color,
) -> None:
    x0 = max(0, int(math.floor(x)))
    y0 = max(0, int(math.floor(y)))
    x1 = min(size, int(math.ceil(x + w)))
    y1 = min(size, int(math.ceil(y + h)))
    for yy in range(y0, y1):
        for xx in range(x0, x1):
            if point_in_rounded_rect(xx + 0.5, yy + 0.5, x, y, w, h, r):
                idx = yy * size + xx
                pixels[idx] = blend(pixels[idx], color)


def draw_circle(pixels: list[Color], size: int, cx: float, cy: float, radius: float, color: Color) -> None:
    x0 = max(0, int(math.floor(cx - radius)))
    y0 = max(0, int(math.floor(cy - radius)))
    x1 = min(size, int(math.ceil(cx + radius)))
    y1 = min(size, int(math.ceil(cy + radius)))
    r2 = radius * radius
    for yy in range(y0, y1):
        for xx in range(x0, x1):
            if (xx + 0.5 - cx) ** 2 + (yy + 0.5 - cy) ** 2 <= r2:
                idx = yy * size + xx
                pixels[idx] = blend(pixels[idx], color)


def draw_polygon(pixels: list[Color], size: int, points: list[tuple[float, float]], color: Color) -> None:
    min_x = max(0, int(math.floor(min(p[0] for p in points))))
    max_x = min(size, int(math.ceil(max(p[0] for p in points))))
    min_y = max(0, int(math.floor(min(p[1] for p in points))))
    max_y = min(size, int(math.ceil(max(p[1] for p in points))))
    for yy in range(min_y, max_y):
        for xx in range(min_x, max_x):
            inside = False
            j = len(points) - 1
            px = xx + 0.5
            py = yy + 0.5
            for i, point in enumerate(points):
                xi, yi = point
                xj, yj = points[j]
                intersects = (yi > py) != (yj > py) and px < (xj - xi) * (py - yi) / ((yj - yi) or 1e-6) + xi
                if intersects:
                    inside = not inside
                j = i
            if inside:
                idx = yy * size + xx
                pixels[idx] = blend(pixels[idx], color)


def downsample(pixels: list[Color], source_size: int, target_size: int) -> list[Color]:
    if source_size == target_size:
        return pixels
    scale = source_size // target_size
    output: list[Color] = []
    for y in range(target_size):
        for x in range(target_size):
            total = [0, 0, 0, 0]
            for yy in range(scale):
                for xx in range(scale):
                    px = pixels[(y * scale + yy) * source_size + (x * scale + xx)]
                    for i in range(4):
                        total[i] += px[i]
            count = scale * scale
            output.append(tuple(v // count for v in total))  # type: ignore[arg-type]
    return output


def render_canvas(size: int) -> list[Color]:
    s = size / 1024.0
    pixels: list[Color] = [(0, 0, 0, 0)] * (size * size)

    def p(value: float) -> float:
        return value * s

    draw_rounded_rect(pixels, size, p(82), p(78), p(860), p(876), p(210), (0, 0, 0, 34))
    draw_rounded_rect(pixels, size, p(70), p(56), p(860), p(876), p(210), (245, 247, 250, 255))
    draw_rounded_rect(pixels, size, p(134), p(150), p(230), p(724), p(116), (232, 39, 55, 255))
    draw_rounded_rect(pixels, size, p(660), p(150), p(230), p(724), p(116), (0, 173, 238, 255))
    draw_rounded_rect(pixels, size, p(320), p(176), p(384), p(672), p(72), (25, 28, 36, 255))
    draw_rounded_rect(pixels, size, p(358), p(228), p(308), p(568), p(44), (38, 42, 53, 255))
    draw_rounded_rect(pixels, size, p(384), p(254), p(256), p(516), p(36), (18, 21, 28, 255))

    # Controller details.
    draw_circle(pixels, size, p(248), p(320), p(54), (255, 255, 255, 226))
    draw_circle(pixels, size, p(248), p(320), p(28), (232, 39, 55, 255))
    draw_circle(pixels, size, p(773), p(320), p(54), (255, 255, 255, 226))
    draw_circle(pixels, size, p(773), p(320), p(28), (0, 173, 238, 255))
    for offset_x, offset_y in ((0, 0), (0, 74), (-37, 37), (37, 37)):
        draw_circle(pixels, size, p(773 + offset_x), p(548 + offset_y), p(19), (255, 255, 255, 210))
    draw_rounded_rect(pixels, size, p(204), p(542), p(88), p(28), p(14), (255, 255, 255, 210))
    draw_rounded_rect(pixels, size, p(234), p(512), p(28), p(88), p(14), (255, 255, 255, 210))

    # Darwin payload mark: compact robot face plus injection bolt.
    draw_rounded_rect(pixels, size, p(416), p(348), p(192), p(136), p(44), (244, 247, 250, 255))
    draw_circle(pixels, size, p(468), p(414), p(17), (18, 21, 28, 255))
    draw_circle(pixels, size, p(556), p(414), p(17), (18, 21, 28, 255))
    draw_rounded_rect(pixels, size, p(492), p(454), p(40), p(8), p(4), (18, 21, 28, 180))
    draw_polygon(
        pixels,
        size,
        [
            (p(540), p(516)),
            (p(490), p(650)),
            (p(544), p(635)),
            (p(506), p(760)),
            (p(630), p(584)),
            (p(568), p(600)),
        ],
        (255, 210, 69, 255),
    )
    draw_circle(pixels, size, p(512), p(512), p(318), (255, 255, 255, 18))

    return pixels


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: generate-app-icon.py /path/to/AppIcon.iconset", file=sys.stderr)
        return 2

    iconset = Path(sys.argv[1])
    iconset.mkdir(parents=True, exist_ok=True)
    base_size = 2048
    rendered: dict[int, list[Color]] = {base_size: render_canvas(base_size)}
    for size in (1024, 512, 256, 128, 64, 32, 16):
        rendered[size] = downsample(rendered[size * 2], size * 2, size)

    specs = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for filename, size in specs:
        write_png(iconset / filename, size, size, rendered[size])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

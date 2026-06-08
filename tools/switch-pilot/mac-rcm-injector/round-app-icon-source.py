#!/usr/bin/env python3
"""Center-crop a PNG and apply a rounded-square alpha mask.

The script intentionally avoids third-party image libraries so the macOS app
builder can run on a fresh machine with only Python 3 and Xcode tools.
"""

from __future__ import annotations

import argparse
import math
import struct
import zlib
from pathlib import Path

Pixel = tuple[int, int, int, int]


def paeth_predictor(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png(path: Path) -> tuple[int, int, list[Pixel]]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"not a PNG file: {path}")

    offset = 8
    width = height = bit_depth = color_type = None
    idat = bytearray()

    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + length]
        offset += 12 + length

        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
                ">IIBBBBB", chunk_data
            )
            if bit_depth != 8 or color_type not in (2, 6) or compression != 0 or filter_method != 0 or interlace != 0:
                raise ValueError("only non-interlaced 8-bit RGB/RGBA PNG files are supported")
        elif chunk_type == b"IDAT":
            idat.extend(chunk_data)
        elif chunk_type == b"IEND":
            break

    if width is None or height is None or bit_depth is None or color_type is None:
        raise ValueError("PNG is missing IHDR")

    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    rows: list[bytearray] = []
    pos = 0
    previous = bytearray(stride)

    for _ in range(height):
        filter_type = raw[pos]
        pos += 1
        row = bytearray(raw[pos : pos + stride])
        pos += stride

        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            up = previous[i]
            up_left = previous[i - channels] if i >= channels else 0
            if filter_type == 1:
                row[i] = (row[i] + left) & 0xFF
            elif filter_type == 2:
                row[i] = (row[i] + up) & 0xFF
            elif filter_type == 3:
                row[i] = (row[i] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                row[i] = (row[i] + paeth_predictor(left, up, up_left)) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"unsupported PNG filter: {filter_type}")

        rows.append(row)
        previous = row

    pixels: list[Pixel] = []
    for row in rows:
        for x in range(width):
            idx = x * channels
            if channels == 4:
                pixels.append((row[idx], row[idx + 1], row[idx + 2], row[idx + 3]))
            else:
                pixels.append((row[idx], row[idx + 1], row[idx + 2], 255))
    return width, height, pixels


def write_png(path: Path, width: int, height: int, pixels: list[Pixel]) -> None:
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixels[y * width + x])

    def chunk(name: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + name
            + payload
            + struct.pack(">I", zlib.crc32(name + payload) & 0xFFFFFFFF)
        )

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def sample_bilinear(pixels: list[Pixel], width: int, height: int, x: float, y: float) -> Pixel:
    x = min(max(x, 0.0), width - 1.0)
    y = min(max(y, 0.0), height - 1.0)
    x0 = int(math.floor(x))
    y0 = int(math.floor(y))
    x1 = min(x0 + 1, width - 1)
    y1 = min(y0 + 1, height - 1)
    tx = x - x0
    ty = y - y0

    def pixel(px: int, py: int) -> Pixel:
        return pixels[py * width + px]

    p00 = pixel(x0, y0)
    p10 = pixel(x1, y0)
    p01 = pixel(x0, y1)
    p11 = pixel(x1, y1)
    values: list[int] = []
    for channel in range(4):
        top = p00[channel] * (1.0 - tx) + p10[channel] * tx
        bottom = p01[channel] * (1.0 - tx) + p11[channel] * tx
        values.append(int(top * (1.0 - ty) + bottom * ty + 0.5))
    return (values[0], values[1], values[2], values[3])


def rounded_rect_alpha(x: float, y: float, size: int, radius: float, antialias: float) -> float:
    half = size / 2.0
    px = abs(x - half)
    py = abs(y - half)
    inner = half - radius
    dx = max(px - inner, 0.0)
    dy = max(py - inner, 0.0)
    distance = math.hypot(dx, dy) - radius
    if distance <= -antialias:
        return 1.0
    if distance >= antialias:
        return 0.0
    return 0.5 - distance / (2.0 * antialias)


def build_icon(source: Path, output: Path, size: int, radius_ratio: float, crop_ratio: float) -> None:
    src_w, src_h, src_pixels = read_png(source)
    crop = int(min(src_w, src_h) * crop_ratio)
    crop = max(1, min(crop, src_w, src_h))
    left = (src_w - crop) / 2.0
    top = (src_h - crop) / 2.0
    radius = size * radius_ratio
    antialias = 1.5
    out: list[Pixel] = []

    for y in range(size):
        for x in range(size):
            sx = left + ((x + 0.5) / size) * crop - 0.5
            sy = top + ((y + 0.5) / size) * crop - 0.5
            r, g, b, a = sample_bilinear(src_pixels, src_w, src_h, sx, sy)
            mask = rounded_rect_alpha(x + 0.5, y + 0.5, size, radius, antialias)
            out.append((r, g, b, int(a * mask + 0.5)))

    write_png(output, size, size, out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--size", type=int, default=1024)
    parser.add_argument("--radius-ratio", type=float, default=0.205)
    parser.add_argument("--crop-ratio", type=float, default=1.0)
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    build_icon(args.source, args.output, args.size, args.radius_ratio, args.crop_ratio)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

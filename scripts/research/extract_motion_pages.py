#!/usr/bin/env python3
"""Extract page headers from a ROBOTIS Action `motion_4096.bin`.

Reads 256 pages of 512 bytes each. Per Framework/include/Action.h (ROBOTIS):
  PAGEHEADER (bytes 0..63)
    [0..13]   name (14 bytes, ASCII, zero-padded)
    [14]      reserved1
    [15]      repeat
    [16]      schedule (0=speed-based, 0x0a=time-based)
    [17..19]  reserved2
    [20]      stepnum (0..7)
    [21]      reserved3
    [22]      speed
    [23]      reserved4
    [24]      accel
    [25]      next   (link to next page after normal play, 0 = stop)
    [26]      exit   (link to exit page on Stop(), 0 = none)
    [27..30]  reserved5
    [31]      checksum
    [32..62]  compliance slope [31]
    [63]      reserved6
  STEP[0..6] (bytes 64..511, 7 x 64 bytes each)
    [0..61]   uint16 position[31]
    [62]      pause
    [63]      time

Outputs a CSV: idx,name,repeat,schedule,stepnum,speed,accel,next,exit,populated
A page is "populated" if name has any printable char OR stepnum > 0.
"""
from __future__ import annotations
import argparse
import csv
import sys
from pathlib import Path

PAGE_SIZE = 512
NUM_PAGES = 256
NAME_LEN = 14


def decode_name(raw: bytes) -> str:
    s = raw.split(b"\x00", 1)[0]
    try:
        return s.decode("ascii", errors="replace").rstrip()
    except UnicodeDecodeError:
        return s.hex()


def parse(path: Path):
    data = path.read_bytes()
    if len(data) != PAGE_SIZE * NUM_PAGES:
        print(f"WARN: {path}: size {len(data)} != expected {PAGE_SIZE*NUM_PAGES}", file=sys.stderr)
    rows = []
    for i in range(NUM_PAGES):
        off = i * PAGE_SIZE
        if off + PAGE_SIZE > len(data):
            break
        page = data[off : off + PAGE_SIZE]
        name = decode_name(page[0:NAME_LEN])
        repeat = page[15]
        schedule = page[16]
        stepnum = page[20]
        speed = page[22]
        accel = page[24]
        nxt = page[25]
        ext = page[26]
        populated = bool(name.strip()) or stepnum > 0
        rows.append({
            "idx": i,
            "name": name,
            "repeat": repeat,
            "schedule": schedule,
            "stepnum": stepnum,
            "speed": speed,
            "accel": accel,
            "next": nxt,
            "exit": ext,
            "populated": int(populated),
        })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bin", type=Path)
    ap.add_argument("--csv", type=Path, default=None)
    ap.add_argument("--only-populated", action="store_true")
    args = ap.parse_args()

    rows = parse(args.bin)
    if args.only_populated:
        rows = [r for r in rows if r["populated"]]

    if args.csv:
        with args.csv.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["idx"])
            w.writeheader()
            w.writerows(rows)
        print(f"Wrote {len(rows)} rows to {args.csv}", file=sys.stderr)
    else:
        for r in rows:
            print(
                f"{r['idx']:3d}  {r['name']:<14s}  steps={r['stepnum']}  "
                f"next={r['next']:3d}  exit={r['exit']:3d}  spd={r['speed']:3d}  "
                f"acc={r['accel']:3d}  rep={r['repeat']:3d}  sch={r['schedule']:#04x}"
            )


if __name__ == "__main__":
    main()

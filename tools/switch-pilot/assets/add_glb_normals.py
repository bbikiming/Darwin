#!/usr/bin/env python3
"""BUILD-TIME ONLY: append vertex normals to the decimated DARwIn GLB.

The cockpit runtime intentionally ships only the baked GLB. This helper is kept
with the other offline model tools so the asset can be regenerated before
packaging.

Usage:
  python3 tools/switch-pilot/assets/add_glb_normals.py \
      tools/switch-pilot/web/assets/darwin.glb \
      tools/switch-pilot/web/assets/darwin.glb
"""

from __future__ import annotations

import json
import math
import os
import struct
import sys
from pathlib import Path
from typing import Any


GLB_MAGIC = b"glTF"
JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942

ARRAY_BUFFER = 34962
TRIANGLES = 4
FLOAT = 5126
UNSIGNED_BYTE = 5121
UNSIGNED_SHORT = 5123
UNSIGNED_INT = 5125

COMPONENT_BYTES = {
    5120: 1,
    5121: 1,
    5122: 2,
    5123: 2,
    5125: 4,
    5126: 4,
}
TYPE_COMPONENTS = {
    "SCALAR": 1,
    "VEC2": 2,
    "VEC3": 3,
    "VEC4": 4,
    "MAT2": 4,
    "MAT3": 9,
    "MAT4": 16,
}


def align4(value: int) -> int:
    return (value + 3) & ~3


def padded(data: bytes, pad_byte: bytes) -> bytes:
    pad = align4(len(data)) - len(data)
    return data + (pad_byte * pad)


def parse_glb(path: Path) -> tuple[dict[str, Any], bytes]:
    raw = path.read_bytes()
    if len(raw) < 20:
        raise ValueError(f"{path} is too small to be a GLB")

    magic, version, declared_length = struct.unpack_from("<4sII", raw, 0)
    if magic != GLB_MAGIC or version != 2:
        raise ValueError(f"{path} is not a glTF 2.0 binary GLB")
    if declared_length != len(raw):
        raise ValueError(f"{path} length mismatch: header={declared_length}, actual={len(raw)}")

    offset = 12
    gltf: dict[str, Any] | None = None
    bin_chunk: bytes | None = None
    while offset < len(raw):
        if offset + 8 > len(raw):
            raise ValueError("truncated GLB chunk header")
        chunk_length, chunk_type = struct.unpack_from("<II", raw, offset)
        offset += 8
        chunk = raw[offset : offset + chunk_length]
        offset += chunk_length
        if len(chunk) != chunk_length:
            raise ValueError("truncated GLB chunk data")
        if chunk_type == JSON_CHUNK:
            gltf = json.loads(chunk.rstrip(b" \t\r\n\x00").decode("utf-8"))
        elif chunk_type == BIN_CHUNK:
            bin_chunk = chunk

    if gltf is None or bin_chunk is None:
        raise ValueError("GLB must contain one JSON chunk and one BIN chunk")
    bin_length = gltf["buffers"][0]["byteLength"]
    bin_payload = bin_chunk[:bin_length]
    return gltf, bin_payload


def accessor_layout(gltf: dict[str, Any], accessor_index: int) -> tuple[dict[str, Any], dict[str, Any], int, int, int]:
    accessor = gltf["accessors"][accessor_index]
    if "sparse" in accessor:
        raise ValueError("sparse accessors are not supported by this build helper")
    if "bufferView" not in accessor:
        raise ValueError(f"accessor {accessor_index} has no bufferView")

    buffer_view = gltf["bufferViews"][accessor["bufferView"]]
    if buffer_view.get("buffer", 0) != 0:
        raise ValueError("only GLB buffer 0 is supported")

    comp_size = COMPONENT_BYTES[accessor["componentType"]]
    comp_count = TYPE_COMPONENTS[accessor["type"]]
    elem_size = comp_size * comp_count
    stride = buffer_view.get("byteStride", elem_size)
    base = buffer_view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    return accessor, buffer_view, base, stride, elem_size


def read_positions(gltf: dict[str, Any], bin_payload: bytes, accessor_index: int) -> list[tuple[float, float, float]]:
    accessor, _buffer_view, base, stride, elem_size = accessor_layout(gltf, accessor_index)
    if accessor["componentType"] != FLOAT or accessor["type"] != "VEC3":
        raise ValueError(f"POSITION accessor {accessor_index} must be FLOAT VEC3")

    positions: list[tuple[float, float, float]] = []
    for i in range(accessor["count"]):
        offset = base + (i * stride)
        end = offset + elem_size
        if end > len(bin_payload):
            raise ValueError(f"POSITION accessor {accessor_index} reads past BIN chunk")
        positions.append(struct.unpack_from("<fff", bin_payload, offset))
    return positions


def read_indices(gltf: dict[str, Any], bin_payload: bytes, accessor_index: int) -> list[int]:
    accessor, _buffer_view, base, stride, elem_size = accessor_layout(gltf, accessor_index)
    if accessor["type"] != "SCALAR":
        raise ValueError(f"indices accessor {accessor_index} must be SCALAR")

    component_type = accessor["componentType"]
    if component_type == UNSIGNED_BYTE:
        fmt = "<B"
    elif component_type == UNSIGNED_SHORT:
        fmt = "<H"
    elif component_type == UNSIGNED_INT:
        fmt = "<I"
    else:
        raise ValueError(f"indices accessor {accessor_index} has unsupported componentType {component_type}")

    indices: list[int] = []
    for i in range(accessor["count"]):
        offset = base + (i * stride)
        end = offset + elem_size
        if end > len(bin_payload):
            raise ValueError(f"indices accessor {accessor_index} reads past BIN chunk")
        indices.append(struct.unpack_from(fmt, bin_payload, offset)[0])
    return indices


def compute_vertex_normals(
    positions: list[tuple[float, float, float]],
    indices: list[int],
) -> list[tuple[float, float, float]]:
    if len(indices) % 3 != 0:
        raise ValueError("triangle index count is not divisible by 3")

    accum = [[0.0, 0.0, 0.0] for _ in positions]
    for tri in range(0, len(indices), 3):
        ia, ib, ic = indices[tri], indices[tri + 1], indices[tri + 2]
        if ia >= len(positions) or ib >= len(positions) or ic >= len(positions):
            raise ValueError("index references a vertex outside the POSITION accessor")

        ax, ay, az = positions[ia]
        bx, by, bz = positions[ib]
        cx, cy, cz = positions[ic]

        ux, uy, uz = bx - ax, by - ay, bz - az
        vx, vy, vz = cx - ax, cy - ay, cz - az
        nx = (uy * vz) - (uz * vy)
        ny = (uz * vx) - (ux * vz)
        nz = (ux * vy) - (uy * vx)

        for idx in (ia, ib, ic):
            accum[idx][0] += nx
            accum[idx][1] += ny
            accum[idx][2] += nz

    normals: list[tuple[float, float, float]] = []
    for nx, ny, nz in accum:
        length = math.sqrt((nx * nx) + (ny * ny) + (nz * nz))
        if length < 1e-12:
            normals.append((0.0, 1.0, 0.0))
        else:
            inv = 1.0 / length
            normals.append((nx * inv, ny * inv, nz * inv))
    return normals


def pack_normals(normals: list[tuple[float, float, float]]) -> bytes:
    out = bytearray()
    for normal in normals:
        out.extend(struct.pack("<fff", *normal))
    return bytes(out)


def iter_primitives(gltf: dict[str, Any]) -> list[dict[str, Any]]:
    primitives: list[dict[str, Any]] = []
    for mesh in gltf.get("meshes", []):
        primitives.extend(mesh.get("primitives", []))
    return primitives


def write_glb(path: Path, gltf: dict[str, Any], bin_payload: bytes) -> None:
    json_payload = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_chunk = padded(json_payload, b" ")
    bin_chunk = padded(bin_payload, b"\x00")

    total_length = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    raw = bytearray()
    raw.extend(struct.pack("<4sII", GLB_MAGIC, 2, total_length))
    raw.extend(struct.pack("<II", len(json_chunk), JSON_CHUNK))
    raw.extend(json_chunk)
    raw.extend(struct.pack("<II", len(bin_chunk), BIN_CHUNK))
    raw.extend(bin_chunk)

    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(raw)
    os.replace(tmp, path)


def add_normals(src: Path, dst: Path) -> tuple[int, int, int]:
    gltf, bin_payload = parse_glb(src)
    primitives = iter_primitives(gltf)
    has_normals = ["NORMAL" in primitive.get("attributes", {}) for primitive in primitives]
    if has_normals and all(has_normals):
        if src != dst:
            dst.write_bytes(src.read_bytes())
        return 0, 0, len(bin_payload)
    if any(has_normals):
        raise ValueError("mixed NORMAL state found; regenerate a clean GLB before adding normals")

    appended_bytes = 0
    processed = 0
    bin_out = bytearray(bin_payload)
    gltf.setdefault("bufferViews", [])
    gltf.setdefault("accessors", [])

    for primitive in primitives:
        if primitive.get("mode", TRIANGLES) != TRIANGLES:
            raise ValueError("only TRIANGLES primitives are supported")
        attributes = primitive.setdefault("attributes", {})
        if "POSITION" not in attributes:
            raise ValueError("primitive is missing POSITION")

        positions = read_positions(gltf, bytes(bin_out), attributes["POSITION"])
        if "indices" in primitive:
            indices = read_indices(gltf, bytes(bin_out), primitive["indices"])
        else:
            indices = list(range(len(positions)))
        normals = compute_vertex_normals(positions, indices)
        normal_payload = pack_normals(normals)

        normal_offset = align4(len(bin_out))
        if normal_offset > len(bin_out):
            bin_out.extend(b"\x00" * (normal_offset - len(bin_out)))
        bin_out.extend(normal_payload)

        buffer_view_index = len(gltf["bufferViews"])
        gltf["bufferViews"].append(
            {
                "buffer": 0,
                "byteOffset": normal_offset,
                "byteLength": len(normal_payload),
                "target": ARRAY_BUFFER,
            }
        )

        accessor_index = len(gltf["accessors"])
        mins = [min(normal[i] for normal in normals) for i in range(3)]
        maxs = [max(normal[i] for normal in normals) for i in range(3)]
        gltf["accessors"].append(
            {
                "bufferView": buffer_view_index,
                "byteOffset": 0,
                "componentType": FLOAT,
                "count": len(normals),
                "type": "VEC3",
                "min": mins,
                "max": maxs,
            }
        )
        attributes["NORMAL"] = accessor_index
        appended_bytes += len(normal_payload)
        processed += 1

    gltf["buffers"][0]["byteLength"] = len(bin_out)
    write_glb(dst, gltf, bytes(bin_out))
    return processed, appended_bytes, len(bin_out)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2

    src = Path(argv[1])
    dst = Path(argv[2])
    before = src.stat().st_size
    processed, appended_bytes, bin_bytes = add_normals(src, dst)
    after = dst.stat().st_size

    if processed == 0:
        print(f"{dst}: all primitives already have NORMAL; unchanged")
        return 0

    print(
        f"{dst}: added NORMAL to {processed} primitives, "
        f"+{appended_bytes} normal bytes, BIN={bin_bytes} bytes, "
        f"file {before} -> {after} bytes"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

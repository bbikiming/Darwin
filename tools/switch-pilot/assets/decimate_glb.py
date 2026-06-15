#!/usr/bin/env python3
"""BUILD-TIME ONLY — decimate the baked DARwIn GLB so the camera-fallback model
is light enough for the Switch's weak Tegra GPU (fewer triangles = faster draw +
smaller file). Quadric-collapse decimation that keeps the rig/node transforms and
per-part materials.

Requires trimesh + fast-simplification (not a runtime dep). Run in a venv:
  python3 -m venv /tmp/dfvenv && /tmp/dfvenv/bin/pip install trimesh fast-simplification
  /tmp/dfvenv/bin/python tools/switch-pilot/assets/decimate_glb.py \
      tools/switch-pilot/web/assets/darwin.glb \
      tools/switch-pilot/web/assets/darwin.glb 0.3
"""

from __future__ import annotations

import sys

import trimesh


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2
    src, dst = argv[1], argv[2]
    keep = float(argv[3]) if len(argv) > 3 else 0.3  # fraction of faces to keep
    scene = trimesh.load(src, process=False)
    geoms = scene.geometry if hasattr(scene, "geometry") else {"mesh": scene}
    before = after = 0
    for name, g in list(geoms.items()):
        if not hasattr(g, "faces") or len(g.faces) == 0:
            continue
        before += len(g.faces)
        # API takes target_reduction = fraction of faces to REMOVE (0..1).
        reduction = min(0.95, max(0.0, 1.0 - keep))
        d = g.simplify_quadric_decimation(reduction)
        d.visual = g.visual  # keep the per-part material/color
        scene.geometry[name] = d
        after += len(d.faces)
    scene.export(dst)
    print(f"faces {before} -> {after}  ({after / max(1, before) * 100:.0f}%)  -> {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

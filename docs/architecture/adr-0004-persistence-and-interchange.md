# ADR-0004: SwiftData for persistence; WireViz YAML for harness interchange

- **Status:** Accepted
- **Date:** 2026-05-09

## Context

Two interrelated questions:

1. How does the application persist its state (robots, harnesses,
   maintenance logs, test records)?
2. How does harness data round-trip to/from the rest of the world?

Persistence options considered: SwiftData, Core Data directly, GRDB
(SQLite via Swift), file-system + plain files (JSON/YAML), git-tracked
markdown.

Interchange options for harness diagrams: WireViz YAML, Altium harness
exports, KiCad schematic export, custom JSON, none (export to PDF only).

## Decision

**Persistence: SwiftData.** Native to the platform, integrated with
SwiftUI's `@Query`, supports `@Model` migrations (verbose but
manageable). The schema is small (≈12 entity types) and stable enough
that SwiftData's migration limitations are unlikely to bite.

**Harness interchange: WireViz YAML.** [WireViz](https://github.com/wireviz/WireViz)
is the de-facto open-source harness format, encodes connectors,
pinouts, conductors, gauges, and BOM, and renders directly to PNG/SVG
via Graphviz. It is plain text and lives well in git, which makes a
harness change show up as a reviewable diff. DarwinForge ships a
two-way bridge:

- `scripts/import_wireviz.py harness.yaml` → SwiftData store
- `scripts/export_wireviz.py harness-id` → YAML + rendered SVG/PNG

The on-disk YAML at `docs/harness/<robot>/<harness>.yaml` is the
**source of truth for diagrams**; SwiftData holds the same structured
data plus the maintenance/test history that does not belong in a
diagram.

## Consequences

- **Positive:** harness diagrams are readable and diff-able in pull
  requests; the user gets a free open-source rendering pipeline.
- **Positive:** SwiftData's `@Query` keeps the UI binding boilerplate
  minimal.
- **Negative:** SwiftData migrations require care. Mitigated by
  exporting to WireViz YAML on every commit so a schema break can be
  recovered from text files.
- **Negative:** WireViz is Python; DarwinForge needs a vendored
  interpreter or a runtime detection. Mitigation: `WireVizBridge`
  shells out to the user's `python3` and surfaces a friendly install
  hint if missing.

## Open question

Whether to ship a Swift port of WireViz so the rendering pipeline is
fully Swift. Punt for now — the Python original works, is maintained,
and the diagrams render in seconds.

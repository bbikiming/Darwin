# scripts/

자동화 스크립트.

## Phase 0

- [`bootstrap-tools.sh`](bootstrap-tools.sh) — git/python3/node/cargo/swift/brew 점검
- [`check-mac-drivers.sh`](check-mac-drivers.sh) — FTDI VCP / CP210x / Apple In-Kernel 드라이버 상태

## 기존 (Phase 0 이전)

- [`render_wireviz.sh`](render_wireviz.sh) — `harness/**/*.yaml` → SVG/BOM (WireViz 필요)
- [`firmware_backup.sh`](firmware_backup.sh) — 로봇 onboard `/darwin/Data` SSH 스냅샷
- [`dxl_scan.sh`](dxl_scan.sh) — 향후 `forge` CLI에 위임할 ID 스캔 wrapper

## Phase 3+

- `harness/probe.sh` — 연결 테스트 (포트·모터 핑·전압)

## Phase 5+

- `build-release.sh` — Mac `.app` 번들 (서명은 추후)

## 사이클 270+ (V270-2)

- [`fitness-check.sh`](fitness-check.sh) — Architectural fitness function gate
  (파일 LOC 800 ceiling, SwiftLint custom rules). pre-commit hook 으로 사용 권장.
  상세: [`docs/guides/FITNESS_FUNCTIONS.md`](../docs/guides/FITNESS_FUNCTIONS.md)

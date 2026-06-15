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

## 사이클 275+ (V275-4) — 실 robot smoke test 자동화

`scripts/smoke/` 디렉토리 — DARwIn-OP2 실 hardware 검증 자동화.

- [`smoke/_lib.sh`](smoke/_lib.sh) — 공통 helper (color / SSH / env 검증 / cleanup)
- [`smoke/preflight-check.sh`](smoke/preflight-check.sh) — SSH / 배터리 / dxlPower / IMU 사전 점검
- [`smoke/deploy-and-verify.sh`](smoke/deploy-and-verify.sh) — 빌드 + 설치 + 시동 + harness 세션 검증
- [`smoke/walk-cycle-smoke.sh`](smoke/walk-cycle-smoke.sh) — Onboard walking_engine_command 검증
- [`smoke/recovery-smoke.sh`](smoke/recovery-smoke.sh) — 비상정지 + 복구 검증
- [`smoke/run-all-smoke.sh`](smoke/run-all-smoke.sh) — 4 단계 통합 entry

환경 변수: `ROBOTIS_HOST`, `ROBOTIS_USER`, `ROBOTIS_SSH_KEY` (선택), `ROBOTIS_SSH_PORT` (선택).

수동 검증 checklist: [`docs/walk-lab/SMOKE_TEST_CHECKLIST.md`](../docs/walk-lab/SMOKE_TEST_CHECKLIST.md).

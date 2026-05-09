# harness/shared/

OP1/OP2 양쪽에 공통으로 적용되는 하네스 자료.

## 구성 (Phase 3에서 작성)

- `cable-specs.md` — 호스트↔로봇 통신 케이블, 전원 케이블, e-stop 인라인 토글
- `mac-driver-setup.md` — FTDI VCP, Silicon Labs CP210x, Apple In-Kernel
- `wiring-diagram.svg` (또는 `.mmd` mermaid) — Mac ↔ 외부 전원 ↔ 로봇 ↔ U2D2 결선도
- `safety.md` — 케이블 텐션, 모터 과열, 정전 시 동작

## 도구

- [`../../scripts/check-mac-drivers.sh`](../../scripts/check-mac-drivers.sh) — Mac 드라이버 상태 점검
- (Phase 3) `../../scripts/harness/probe.sh` — 연결 테스트

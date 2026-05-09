# PROGRESS

> 살아있는 진행 상태. 단계 종료 시마다 갱신·체크포인트 커밋·`docs/reports/PHASE_{N}_REPORT.md` 작성.
> 사용자 승인 모드: **한 번 승인 후 끝까지 자율** (2026-05-09 결정).

## Phase 진행 상태

- [x] **Phase 0 — Bootstrap** (워크스페이스 초기화, 도구 검증, 빈 구조 생성)
- [x] **Phase 1 — Discovery & Archive** (오픈소스 발굴·아카이브 — 26 엔트리, 4 클론)
- [x] **Phase 2 — Knowledge Synthesis** (5개 신규 명세 + 2개 보존)
- [x] **Phase 3 — Harness Engineering** (BOM·결선·드라이버·probe.sh + ADR-006/7/8)
- [x] **Phase 4 — App Architecture** (ADR-009..013, Cargo workspace 18 tests)
- [x] **Sprint 1** Connection Layer (PosixSerial + Bus + CmController, 26 tests)
- [x] **Sprint 2** Live Joint Control (Sync R/W + JointController + safety, 35 tests)
- [x] **Sprint 3** Motion Import/Export (.mtn ↔ JSON round-trip, 43 tests)
- [x] **Sprint 4** Motion Editor 골격 (timeline + library + SwiftUI stub, 50 tests)
- [x] **Sprint 5** Walk Engine MVP (params + engine + IMU + sim CLI, 59 tests)
- [x] **Sprint 6** Vision & Strategy MVP (HSV blob + FSM + sim CLI, **73 tests**)

## 🎉 MVP 달성 (2026-05-09)

ROADMAP §5 MVP 정의 100% 충족:
- Sprint 1~3 완성, Sprint 4 골격, Sprint 5/6 데이터 모델
- forge-core: 73 tests / cargo build / clippy / fmt 모두 GREEN
- `forge` CLI 9 서브커맨드: ports / ping / scan / board / list-joints /
  joint{set,state,torque,estop} / motion{import,export,inspect} /
  walk / strategy

## 통계

| 항목 | 값 |
|------|-----|
| 단계별 보고서 | 11개 (Phase 0~4 + Sprint 1~6) |
| ADR | 13개 (ADR-001~013) |
| 명세 문서 | 12개 (protocols/motion-format/architecture/harness) |
| Rust modules | 13개 (control, controller, dynamixel{bus,sync,v1,v2}, error, joint{state}, motion{page,parser,writer,timeline,library}, serial{loopback,posix}, strategy, vision{frame,segmentation}, walk{engine,imu,params}) |
| Rust tests | 73 / 73 통과 |
| Hardware BOM 부품 | 18개 (OP1 15 + OP2 3 추가) |
| Research INDEX 엔트리 | 26개 (ROBOTIS 공식 + 1세대 + 커뮤니티 + 학술) |

## 직전 체크포인트

- 커밋: `<latest> sprint-6: vision & strategy MVP`
- 브랜치: `claude/robotis-darwin-op-setup-oyzTi`
- PR: #1 (draft, MVP 완료 후 갱신)

## 다음 단계 (사용자 결정)

MVP가 달성되었으므로 후속 우선순위는 사용자 선택:
1. **Mac 측 SwiftUI 본 구현** — forge-core를 staticlib로 임포트, JointControlView/MotionEditorView/WalkTunerView 채움
2. **실기기 검증** — Mac에서 ports/ping/scan/board/joint state 실 실행, 트레이스 캡처
3. **walk loop 실 활성화** — IK 보강 + IMU 닫힌 루프 + walk_ready 자세 검증
4. **카메라 + strategy 통합** — AVFoundation Frame ↔ forge-core::vision 어댑터
5. **PR #1 ready for review 전환** — 문서 + 코드 리뷰

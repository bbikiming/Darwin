# Mac 통합 작업 프롬프트 v2 — 3 PR 머지 후

> 2026-05-12 클라우드 작업 결과 PR #1 / #2 / #3 모두 `main` 으로 머지 완료.
> 본 문서는 머지된 main 위에서 Mac 빌드·검증·UI 통합을 진행하기 위한 핸드오프.
> 이전 버전 (`2026-05-12-walk-lab-mac-integration.md`) 는 PR #1 단독 시점이라 outdated.

---

## 통합된 main 상태 (2026-05-12)

```
main HEAD = 6811363 (Merge PR #2: Remote Teleop v1 PRD)

PR #1 (1f50989) — Rust 코어 286 + cli 10 + mcp 30 + lib 5 = 331 tests
                  Walk Lab v1 (8 preset, sim IMU/온도, 4-layer safety)
                  데이터 적정성 회귀 + ROBOTIS 1:1 정렬
                  C1/C2/C3/H2~H5/M1~M4 BLOCKERS 해결

PR #3 (e79c53c) — 커뮤니티 모션 DB 4 저장소 + 6 motion bin
                  Walk Lab 6-슬라이더 안전 점수 + smart-clamp
                  WalkStabilityPredictor (Swift)
                  19 starter motion + motions/external/

PR #2 (6811363) — Remote Teleop v1 PRD 문서 4 파일 (코드 0)
```

---

## 프롬프트 (Mac Claude Code 에 그대로 붙여넣기)

```text
클라우드에서 PR #1 / #2 / #3 모두 main 으로 머지 완료. main HEAD = 6811363.
다음 순서로 진행해 줘:

## 1. 로컬 동기화

cd ~/Documents/vibe_coding/claude-forge  # 본인 경로

# 현재 위치 확인
git branch --show-current
git status

# main 으로 전환 + 최신 받기
git checkout main
git pull origin main

# HEAD 가 6811363 (Merge PR #2) 여야 함
git log --oneline -5

# (선택) 머지된 로컬 feature branch 정리
git branch -d claude/robotis-darwin-op-setup-oyzTi 2>/dev/null
git fetch --prune

## 2. Rust 빌드 + 테스트

cd app/core
cargo build --workspace
cargo test --workspace 2>&1 | tail -10
# 결과: forge-core 286 + forge-cli 10 + forge-mcp-synth 30 + lib 5 = 331 통과
# (PR #3 가 Swift 측만 추가했으므로 Rust 테스트 수는 PR #1 머지 시점과 동일)
# FAIL 시 즉시 보고.

## 3. cbindgen 헤더 재생성

cd ../..   # 리포 루트
./scripts/build-mac.sh
# 또는 수동으로:
# cargo install cbindgen
# cbindgen --crate forge-ffi --output app/ui/DarwinForge/Vendor/CForgeCore/include/forge_core.h

# 검증: 새 함수가 헤더에 있어야 함
grep "fc_walk_set_period_ms" app/ui/DarwinForge/Vendor/CForgeCore/include/forge_core.h
# → "int fc_walk_set_period_ms(struct fc_walk *h, double period_ms);" 1줄

## 4. Swift 빌드

cd app/ui/DarwinForge
swift build 2>&1 | tail -30
# 또는 Xcode 에서 DarwinForge.xcodeproj 열고 ⌘B

# 신규 파일 6 개가 컴파일에 포함됐는지 확인:
ls Sources/DarwinForgeUI/WalkLab/Components/AdvancedSlidersPanel.swift
ls Sources/DarwinForgeUI/WalkLab/Components/SafetyBandedSlider.swift
ls Sources/ForgeCore/WalkStabilityPredictor.swift
ls Sources/DarwinForgeUI/Motion/ReferenceMotionLibrary.swift
ls Tests/ForgeCoreTests/WalkStabilityPredictorTests.swift
ls Tests/DarwinForgeUITests/StarterMotionLibraryTests.swift

# Swift 테스트 (Mac 한정)
swift test 2>&1 | tail -10
# → WalkStabilityPredictorTests + StarterMotionLibraryTests 통과 확인

## 5. RootView 통합 (1줄 교체)

Sources/DarwinForgeUI/RootView.swift line 646:

  변경 전:  case .walk:     WalkSimView()
  변경 후:  case .walk:     WalkLabView()

(import ForgeCore 이 파일 상단에 이미 있으면 OK, 없으면 추가)

swift build 다시 → 통과 확인 후 다음 단계.

## 6. UI 수동 검증 (시뮬 단계)

앱 실행 (⌘R / `swift run` / Xcode Run). 다음 7 단계:

### 6-1. Walk Lab 진입 + Sim only 배너
- 사이드바 ⌘4 또는 "워크 랩" 클릭 → WalkLabView 화면.
- 상단 파란 배너: "Sim only — 실 IK 미구현 (BLOCKER C3)" ✓
- 사이드바 상단: "정비 스탠드에 거치됨" 체크박스 — **꺼진** 상태.
- 8 preset 버튼 모두 disabled (cradle 미확인 상태).
- 사이드바 하단 "세션 기록" 비어 있음.

### 6-2. Cradle confirm + Safe preset
- "정비 스탠드에 거치됨" 체크 → 8 preset 활성화.
- "보통 속도" 클릭 → 시뮬 시작.
  * 발 자취 (가운데 2D 캔버스) 에 파랑/주황 점이 0.5초 정도 흐름.
  * Roll/Pitch 게이지: 부드럽게 흔들림 (4° / 2° 진폭).
  * Phase 카드: PHASE0 → PHASE1 → PHASE2 → PHASE3 순환.
  * Temp 표시: 35.x°C 에서 천천히 증가 (0.1°C/s).
  * Elapsed: 50ms 단위로 증가.
- "정지" 클릭 → sim 멈춤, 세션 기록에 "보통 속도 × Ns" 추가.

### 6-3. 고급 6-슬라이더 + 안전 점수
- "고급 — 슬라이더 조정" 토글 ON.
- 6 슬라이더 노출:
  1. **보폭 stride** (0..50 mm/cycle) — 색대역: 0..30 녹색 / 30..40 노랑 / 40..50 빨강
  2. **측면 side** (-25..25 mm/cycle)
  3. **회전 turn** (-20..20 °/cycle)
  4. **주기 period** (400..800 ms)
  5. **발 들기 footHeight** (15..80 mm)
  6. **균형 게인 balance** (0.5..2.0)
- 사이드바에 **낙상 위험 점수** 게이지 표시 (0..100):
  - 0..30 Safe (녹), 30..60 Caution (노), 60..80 HighRisk (주황), 80+ Critical (빨강).
- "보통 속도" 시작 후 stride 슬라이더를 끌어 올림:
  * 점수 증가 + sim 발 자취 즉시 변화 (PR #1 의 syncCommandToEngine).
  * Critical 도달 (80+) 시 빨간 배너 "낙상 위험 점수 X/100 — 시작 차단" 등장.
- 새 preset 시작 시도 → critical 점수면 `start()` 가 차단. 슬라이더 줄이면 다시 가능.

### 6-4. HighRisk preset (jog) 위험 확인 시트
- 토글 OFF (preset 모드).
- "달리기" 클릭 → 위험 확인 sheet (빨간 톤).
- "위험 감수하고 실행" 버튼: 체크 안 했으면 disabled.
- "위험을 인지하고 진행합니다" 체크 → 버튼 enable.
- 실행 → sim 시작. 15s 후 자동 stop (`max_duration_secs=15`) 확인.

### 6-5. 안전 게이트 (sim only)
**중요**: 실 모터 없이 sim 데이터만으로 자동정지 게이트 발동 확인.

a) **IMU 30° 게이트** — 현 sim 모델 max sway 6° 라 자연 도달 안 함.
   * 코드 리뷰로 확인: `WalkLabSession.tick()` 의
     `if abs(imuRollDeg) > 30 || abs(imuPitchDeg) > 30 { emergencyStop() }`
   * 또는 임시 `updateSimIMU` 의 baseRoll 4.0 → 35.0 으로 수정 후 1회 검증 후 복원.

b) **모터 60°C 게이트** — 0.10 °C/s 기본은 250 s 후 도달.
   * 코드 리뷰 또는 `motorHeatRate=5.0` 임시 변경.
   * Temp 표시 색이 35°→45°→50°→60° 임계 변화 (회색→노→주→빨) 확인.

### 6-6. ESC 비상정지
- 워킹 중 ESC 키 → 즉시 정지 + risk_acknowledged 리셋.
- 다시 jog 클릭 → 위험 확인 sheet 재출현 (체크 해제됨).

### 6-7. Motion Studio (선택, PR #3 검증)
- 사이드바에서 모션 카탈로그 진입.
- PR #3 가 추가한 19 starter motion + reference library 등장 확인.
- `motions/external/` 의 .bin 6 종이 참고 자료로 열람 가능.

## 7. 발견 사항 보고

이슈가 있다면 카테고리별로 정리:
- **컴파일 에러** (Swift / Rust / cbindgen): 정확한 에러 메시지
- **시각/레이아웃**: SwiftUI 가 클라우드에서 못 본 부분 (간격, 색, 글씨 잘림)
- **동작**: 슬라이더가 sim 에 반영 안 되거나, 안전 점수 부정확, 자동정지 미발동 등
- **UX**: 사용 중 느낀 흐름 문제

## 8. 실 모터 송출 — 여전히 금지

이번 작업은 sim 단계만. 실 robot 송출은:
- **BLOCKER C3** (`walk::engine` 실 IK 미구현) 해결 전까지 금지.
- `forge motion play --engage` 가 만약 호출되더라도 Walk Lab preset 의
  (x_amp, y_amp, a_amp) 를 실 motor 로 보내지 않도록 분리됨.
- 현재 단계: Mac 앱 UI 동작 검증 + cargo test 통과 검증까지.

## 9. 다음 단계 후보 (Mac 검증 결과 본 후 결정)

1. **C3 해결 — 실 IK 포팅** (가장 큰 잔여 작업, Sprint X).
   - ROBOTIS `op2_walking_module.cpp::computeLegAngle` 의 13× wSin 식 + 6-DOF
     IK (hip yaw/roll/pitch + knee + ankle pitch/roll) 를 Rust 포팅.
   - 실 IMU 폴링 wire (현재 sim 자리에 실 값 주입).
2. **Sprint 15 — Teleop v1 구현** (PR #2 PRD 기반).
   - `forge-core::teleop` 모듈 + Remote Pilot 화면 (⌘8).
3. **H1 — self_collision 5번째 룰** (hip + knee 결합).
4. **M5 / M6 — OFFICIAL_CATALOG 오타 / page-format.md TODO 정리** (잡일).

Mac 검증 결과를 알려주면 우선순위 정해서 다음 라운드 진행.
```

---

## 빠른 sanity check (Mac 5분)

```bash
# main HEAD 확인
git log --oneline -1
# → 6811363 Merge PR #2: Remote Teleop v1 PRD

# Rust 테스트
cd app/core && cargo test --workspace 2>&1 | tail -3
# → 331 tests passed

# 핵심 신규 파일 존재 확인
ls -la app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/
# → AdvancedSlidersPanel.swift, FootTrailCanvas.swift, IMUGauge.swift,
#   PresetButton.swift, SafetyBandedSlider.swift 5 개

ls -la app/ui/DarwinForge/Sources/ForgeCore/
# → CForgeCore.swift, Connection.swift, Motion.swift, Strategy.swift, Vision.swift,
#   Walk.swift, WalkStabilityPredictor.swift 등

ls motions/external/_catalog/*.csv
# → 6 CSV 파일 (외부 모션 라이브러리 카탈로그)
```

## 변경 사항 한눈에 (이전 핸드오프 대비)

| | v1 (`2026-05-12-walk-lab-mac-integration.md`) | v2 (본 문서) |
|---|---|---|
| 풀 대상 | `claude/robotis-darwin-op-setup-oyzTi` branch | `main` (3 PR 머지됨) |
| Walk Lab 슬라이더 | 4 (x/y/a/period, m 단위) | **6** (stride/side/turn/period/footHeight/balance, mm·°·ms 단위) |
| 안전 점수 | 없음 | **WalkStabilityPredictor** 0..100 + critical 차단 |
| 신규 Swift 파일 | 6 (WalkLab v1) | 6 + 4 추가 (PR #3 의 panel/slider/predictor/library) |
| 모션 데이터 | catalog fixture 9/16 | + motions/external/ 6 .bin + 19 starter |
| Teleop | 언급 없음 | PR #2 PRD 머지 — Sprint 15 후속 |
| Mac 빌드 검증 시점 | PR #1 머지 전 | **모든 PR 머지 후** |

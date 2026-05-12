# Mac 통합 작업 프롬프트 — Walk Lab v1 + 모션·워크 폴리시

> 클라우드 작업분(2026-05-09 ~ 05-12) 을 Mac 로컬에서 통합·빌드·테스트 하기 위한 핸드오프.
> 아래 프롬프트 전체를 Mac 의 Claude Code 세션에 그대로 붙여 넣으세요.

---

## 사전 조건 (Mac 에서 1회만)

- Xcode 16+ / Swift 6 toolchain
- Rust stable + cbindgen (`cargo install cbindgen`)
- `git` 원격 인증 (이미 푸시 가능한 상태 가정)

---

## 프롬프트 (복사 → Mac Claude Code 에 붙여넣기)

```text
지금 클라우드에서 모션·워크 폴리시 + Walk Lab v1 + 데이터 적정성 회귀 작업을
완료했어. 다음을 순서대로 진행해 줘:

## 1. 최신 풀

cd ~/Documents/vibe_coding/claude-forge  # 또는 본인의 경로
git fetch origin
git checkout claude/robotis-darwin-op-setup-oyzTi
git pull origin claude/robotis-darwin-op-setup-oyzTi

최근 7개 커밋이 보여야 한다:
- 60b210d test(synth): D — velocity calibration fixture + BLOCKERS H2/H3/M3 해결
- 6399be9 docs(safety): C — JointLimits/torque_ramp provenance docstring
- b2a762c test(motion): B — 4 신규 catalog fixture + byte-preserving decoder
- b1eb81b test(motion+walk): A — D3+D6 회귀 (V1 마진 + WalkPreset sim 박스)
- e47d4b0 feat(walk-lab): W1+W2+W3 + C3 — period plumbing, sim IMU/온도, sim 배너
- 1773f22 fix(synth): C1+C2 — positions[i]=JointId i 규약으로 인덱싱 정정
- (그 이전 H4/H5/M1/M2/M4 폴리시 커밋도 보여야 함)

## 2. 빌드 검증

# Rust 코어
cd app/core
cargo build --workspace
cargo test --workspace
# 286 forge-core + 10 cli + 30 mcp + 5 = 331 tests 통과해야 함.
# (FAIL 있으면 즉시 중단하고 알려 줘 — 클라우드와 환경 차이 가능성)

# C 헤더 재생성 (Rust FFI 가 새 함수 fc_walk_set_period_ms 추가됨)
cd ../..
./scripts/build-mac.sh  # 또는 cbindgen 직접 실행
# 결과: app/ui/DarwinForge/Vendor/CForgeCore/include/forge_core.h 에
#   `int fc_walk_set_period_ms(struct fc_walk *h, double period_ms);` 줄이 있어야 함.

# Swift 앱 빌드
cd app/ui/DarwinForge
swift build 2>&1 | tail -30
# 또는 Xcode 에서 DarwinForge.xcodeproj 열고 ⌘B.
# 컴파일 에러가 있다면 클라우드에서 못잡은 Swift 측 이슈 — 보고해 줘.

## 3. RootView 통합 (1줄 교체)

app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift 의 line 646:

  변경 전:  case .walk:     WalkSimView()
  변경 후:  case .walk:     WalkLabView()

ImportForgeCore 가 이미 추가되어 있는지 확인 (없으면 파일 상단에 `import ForgeCore`).

swift build 다시 → 통과 확인.

## 4. UI 수동 검증 (시뮬 단계)

앱 실행 (⌘R 또는 `swift run`). 다음 시나리오를 차례로:

### 4-1. Walk Lab 진입
- 사이드바 ⌘4 또는 "워크 랩" 클릭 → WalkLabView 화면 등장.
- 상단에 파란 "Sim only — 실 IK 미구현 (BLOCKER C3)" 배너 보임 ✓
- 사이드바 상단에 "정비 스탠드에 거치됨" 체크박스 — **꺼진** 상태.
- 8개 프리셋 버튼이 모두 disabled (cradle 미확인) ✓
- 사이드바 하단 "세션 기록" 비어 있음.

### 4-2. Cradle confirm + Safe 프리셋
- "정비 스탠드에 거치됨" 체크 → 8 프리셋 활성화.
- "보통 속도" 클릭 → 시뮬 시작.
  * 발 자취 (가운데 2D 캔버스) 에 파랑/주황 점이 0.5초 정도 흐름.
  * Roll/Pitch 게이지가 부드럽게 흔들림 (4° / 2° 진폭).
  * Phase 카드: PHASE0 → PHASE1 → PHASE2 → PHASE3 순환.
  * Temp 표시: 35.x°C 에서 천천히 증가 (0.1°C/s).
  * Elapsed: 50ms 단위로 증가.
- "정지" 클릭 → sim 멈춤, 세션 기록에 "보통 속도 × Ns" 추가.

### 4-3. 슬라이더 풀-스윙
- "고급 — 슬라이더 조정" 토글 ON → 4 슬라이더 노출.
- "보통 속도" 다시 시작 → 슬라이더 움직이는 동안 발 자취 변화 즉시 반영 (W1 검증).
- 보폭 x = 0.05 (최대), 주기 = 400 ms 로 끌어보기 — 발 자취 더 멀리, 빨리 진동.
- 정지 → 다른 프리셋 클릭 → 슬라이더 값 무시되고 프리셋 기본값으로 (advanced 토글 OFF 시).

### 4-4. HighRisk (jog) 위험 확인 시트
- "달리기" 클릭 → 위험 확인 sheet 등장 (빨간 톤).
- "위험 감수하고 실행" 비활성 (체크 안 했음).
- "위험을 인지하고 진행합니다" 체크 → 버튼 활성.
- "위험 감수하고 실행" 클릭 → 시뮬 시작.
- 15초 후 자동 stop (`max_duration_secs=15`) 확인.

### 4-5. 안전 게이트 시각 검증 (sim only)
**중요**: 실 모터 없이 sim 데이터만으로 자동정지 게이트가 발동하는지 확인.

a) **IMU 30° 게이트**: 슬라이더 보폭 x = 0.05, 주기 = 400 ms 로 빠르게 진동 →
   현 sim 모델에서는 max sway 6° 정도라 30° 도달 안 함. **수동 트리거 확인**:
   - Swift LLDB 또는 디버그 도구로 `session.imuRollDeg = 35` 강제 주입 →
     다음 tick 에서 자동 stop + "균형 잃음" 빨간 배너 등장해야 함.
   - 또는 임시로 WalkLabSession.updateSimIMU 의 baseRoll 을 35.0 으로 hardcode 후
     확인하고 다시 4.0 으로 되돌리기 (이건 안 해도 됨, 코드 검사로 충분).

b) **모터 60°C 게이트**: 한참 워킹하면 350초 후 도달.
   - 빠른 확인은 `motorHeatRate = 5.0` 으로 임시 변경 후 ~5초 만에 트리거.
   - 또는 코드 리뷰만: WalkLabSession.tick() 의 `if maxMotorTemp >= 60` 분기 확인.

### 4-6. ESC 비상정지
- 워킹 중 ESC 키 → 즉시 정지 + risk_acknowledged 리셋.
- 다시 jog 클릭 → 위험 확인 sheet 재출현 (체크 해제됨).

## 5. 발견 사항 보고

이슈가 있다면 아래 카테고리로 정리:
- **컴파일 에러**: Swift / Rust / cbindgen 측 정확한 에러 메시지
- **시각/레이아웃**: SwiftUI 가 컨테이너에서 못 본 부분 (간격, 색, 글씨 잘림)
- **동작**: 슬라이더가 sim 에 반영 안 되거나, 자동정지가 발동 안 하거나 등
- **개선 아이디어**: 사용 중 느낀 UX 문제

발견사항 정리되면 그걸 바탕으로 후속 작업 결정.

## 6. 실 모터 송출은 아직 금지 (다시 한 번 주의)

이번 Walk Lab v1 은 **WalkEngine sim 위에서만 동작**. 실 robot 송출은:
- BLOCKER C3 (`walk::engine` 의 실 IK 미구현) 가 해결되어야 함.
- `forge motion play --engage` 류 명령은 만약 시도하더라도 walk preset 을 절대
  실 motor 로 보내지 않음. JointController/JointSet 직접 호출도 금지.
- 현재는 Mac 앱 UI 동작 검증 + cargo test 통과 검증까지.

## 7. 다음 단계 후보 (Mac 검증 후 결정)

1. **C3 해결 — 실 IK 포팅** (가장 큰 잔여 작업, 별도 Sprint).
   - ROBOTIS `op2_walking_module.cpp::computeLegAngle` 의 13× wSin 식 + 6DOF
     IK (hip yaw/roll/pitch + knee + ankle pitch/roll) 를 Rust 포팅.
   - 실 IMU 폴링 wire (현재 sim 모델이 있는 자리에 실 값 주입).
2. **H1 self_collision 5번째 룰** — hip + knee 결합 충돌.
3. **M5/M6 — OFFICIAL_CATALOG 오타 / page-format.md TODO 정리** (잡일).

Mac 검증 결과를 알려주면 우선순위 정해서 다음 라운드 진행.
```

---

## 클라우드 작업 한눈에 (커밋 그래프)

```
60b210d  test(synth): D — velocity calibration fixture
6399be9  docs(safety): C — JointLimits/torque_ramp provenance
b2a762c  test(motion): B — 4 신규 catalog fixture + byte-preserving decoder
b1eb81b  test(motion+walk): A — D3+D6 회귀 (V1 마진 + WalkPreset sim 박스)
e47d4b0  feat(walk-lab): W1+W2+W3 + C3 — period plumbing, sim IMU/온도, sim 배너
1773f22  fix(synth): C1+C2 — positions[i]=JointId i 규약 정정
(+ H4/H5/M1/M2/M4 폴리시 커밋)
4116f89  feat(walk-lab): 8 프리셋 + 4-레이어 안전 + SwiftUI 스캐폴딩
```

## 클라우드 한계 (다시 명시)

- Mac 빌드 검증 불가 — 컨테이너에 swift/Xcode 미설치
- 실기기 USB 통신 불가 — 가짜 시리얼 백엔드(loopback) 만 사용
- cbindgen 헤더 (`forge_core.h`) 는 Mac 측에서 재생성됨 — 클라우드는 .gitignore

## 빠른 sanity check (Mac 에서 5분)

```bash
cd app/core && cargo test --workspace 2>&1 | tail -3
# → 331 tests passed 보여야 함

ls -la app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/
# → WalkLabView.swift, WalkLabSession.swift, WalkPresetCatalog.swift,
#   Components/IMUGauge.swift, FootTrailCanvas.swift, PresetButton.swift 6개 파일
```

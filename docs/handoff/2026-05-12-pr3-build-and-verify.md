# Mac 빌드·검증 프롬프트 — PR #3 (커뮤니티 모션 DB + Walk Lab 슬라이더 고도화)

> **Session 01FoU9** 의 변경 사항을 Mac 에서 처음 빌드·실행하고 동작을 검증하는 절차.
> 이 문서를 위에서 아래로 한 명령씩 실행. 각 단계에 "성공 시 다음", "실패 시" 분기 명시.
>
> PR: <https://github.com/bbikiming/Darwin/pull/3>
> Branch: `claude/create-motion-darwin-database-trexF`
> 마지막 커밋: `f3f0eae`

---

## 0. 사전 확인 (30 초)

터미널에서:

```sh
# 0-1. 현재 위치 확인 (DarwinForge 리포지토리 루트여야 함)
pwd
# 출력 예: /Users/you/Darwin    또는    /Users/you/DarwinForge

# 0-2. 깨끗한 워킹 트리 확인 (modified 파일 있으면 stash 권장)
git status

# 0-3. 도구 버전 확인
xcode-select -p           # /Applications/Xcode.app/... 또는 /Library/Developer/CommandLineTools
swift --version           # Swift 5.10+ 필요
rustc --version           # Rust 1.78+ 필요
cargo --version
python3 --version         # 3.11+ 권장 (모션 추출 스크립트용)
```

**실패 시:**
- `xcode-select -p` 가 비면: `xcode-select --install` 실행.
- `swift --version` 이 5.10 미만: `softwareupdate -i Command_Line_Tools_for_Xcode...` 또는 App Store 의 Xcode 업데이트.
- `rustc` 가 없으면: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh` → 새 터미널.

---

## 1. 브랜치 가져오기 (1 분)

```sh
# 1-1. 원격 최신화
git fetch origin

# 1-2. 브랜치 체크아웃 (이미 있으면 reset, 새로면 track)
git checkout claude/create-motion-darwin-database-trexF || \
    git checkout -B claude/create-motion-darwin-database-trexF origin/claude/create-motion-darwin-database-trexF

git pull origin claude/create-motion-darwin-database-trexF

# 1-3. 마지막 커밋이 f3f0eae 시작인지 확인
git log -1 --oneline
# 출력 예: f3f0eae feat(walk-lab): 6-슬라이더 안전 색대역 + 낙상 위험 점수 + smart-clamp

# 1-4. 새로 추가된 6 파일이 모두 존재하는지 확인
ls -la \
    app/ui/DarwinForge/Sources/ForgeCore/WalkStabilityPredictor.swift \
    app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/SafetyBandedSlider.swift \
    app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/AdvancedSlidersPanel.swift \
    app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/ReferenceMotionLibrary.swift \
    app/ui/DarwinForge/Tests/ForgeCoreTests/WalkStabilityPredictorTests.swift \
    motions/test/walk-progression-v1.bin
```

**실패 시:** 파일이 없으면 `git pull` 이 실제로 PR #3 의 HEAD 까지 받지 않은 것. `git log -3 --oneline` 으로 확인 후, 필요하면 `git reset --hard origin/claude/create-motion-darwin-database-trexF`.

---

## 2. Rust 코어 + Swift 빌드 (3~6 분)

```sh
# 2-1. 통합 빌드 스크립트 — Rust 코어 + cbindgen 헤더 + Vendor/ 갱신 + Swift 빌드
bash scripts/build-mac.sh -u --swift

# 2-2. 빌드가 통과했다면 .build/ 와 Vendor/CForgeCore/lib/ 가 갱신됨
ls -la app/ui/DarwinForge/Vendor/CForgeCore/lib/
ls -la app/ui/DarwinForge/.build 2>/dev/null | head
```

### 흔한 빌드 에러 + 대처

| 에러 메시지 (요약) | 원인 | 대처 |
|--------------------|------|------|
| `cannot find 'NSEvent' in scope` | macOS SwiftUI ↔ AppKit 임포트 누락 | `SafetyBandedSlider.swift` 최상단에 `#if canImport(AppKit)\nimport AppKit\n#endif` 추가 |
| `value of type 'WalkLabSession' has no member 'strideMm'` | `WalkLabSession.swift` 수정이 안 받아진 것 | `git diff app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift` 으로 확인 |
| `'AdvancedSlidersPanel' is not in scope` | Swift module 캐시 stale | `rm -rf app/ui/DarwinForge/.build && bash scripts/build-mac.sh -u --swift` |
| `Cannot find 'fc_walk_new'` | Rust 코어 libforge_core.a 빌드 안 됨 | `cargo build -p forge-core --release` 단독 실행 후 다시 |
| `cbindgen: command not found` | `cargo install cbindgen` |
| Linker `Undefined symbols` for forge-core | Vendor/ 헤더 stale | `bash scripts/build-mac.sh -u --swift --clean` (clean 플래그) |

빌드가 통과할 때까지 절대 다음 단계로 가지 말 것 — 실행 단계에서의 crash 가 빌드 에러 누락을 가립니다.

---

## 3. 자동 테스트 (1~2 분)

```sh
# 3-1. 전체 테스트 — 통과해야 함
swift test --package-path app/ui/DarwinForge 2>&1 | tail -40

# 3-2. 새로 추가된 테스트만 따로 보고 싶으면:
swift test --package-path app/ui/DarwinForge \
    --filter WalkStabilityPredictorTests 2>&1 | tail -20

swift test --package-path app/ui/DarwinForge \
    --filter StarterMotionLibraryTests 2>&1 | tail -20
```

**기대 결과:**

- `WalkStabilityPredictorTests`: **14 테스트 모두 통과**
  - `testIdleIsZero`, `testSlowWalkIsSafe`, `testFastWalkIsCaution`, `testJogIsHighRisk`,
    `testCriticalBlocksStart`, `testLowFootHeightWarning`, `testNoBalanceCompensationWarning`,
    `testDiagonalComboWarning`, `testEffectiveSpeedCalc`, `testEffectiveSpeedTriggersWarningAt50`,
    `testCapShrinksWhenPeriodShort`, `testCapShrinksWhenBalanceLow`,
    `testCapShrinksWhenFootHeightExtreme`, `testSideAndTurnCapsCoupleWithStride`,
    `testScoreMonotonicWithStride`, `testScoreMonotonicWithSpeedup`
- `StarterMotionLibraryTests`: **신규 2 케이스 포함 모두 통과**
  - `testReferenceMotionLibraryIsIncluded` — 4 카테고리 페이지 등재 확인
  - `testWalkProgressionPagesAreSafe` — 6 페이지 walkReady 시작·종료 보장

**실패 시:**

| 실패 케이스 | 의미 | 대처 |
|-------------|------|------|
| `testWalkProgressionPagesAreSafe` | `MotionStep.from(pose: .walkReady).toPose() != .walkReady` | RobotPose 의 Equatable 정의 또는 JointID.allCases 가 20 개가 아닌 것 |
| `testScoreMonotonicWithStride` | 휴리스틱 임계가 거꾸로 작용 | `WalkStabilityPredictor.swift` 의 `piecewise` knots 점검 |
| 임의의 컴파일 에러 | 위 §2 의 에러 표 참조 |

테스트 결과 (실패 메시지 전체) 를 그대로 복사해서 알려주시면 바로 픽스 가능.

---

## 4. 앱 실행 + 시각 검증 (5~10 분)

```sh
# 4-1. 실행 — 첫 launch 는 incremental link 로 10~30 초 더 걸릴 수 있음
swift run --package-path app/ui/DarwinForge DarwinForgeApp

# (또는 Xcode 로 열고 ⌘R)
# xed app/ui/DarwinForge/Package.swift
```

앱 창이 뜨면 다음 4 가지 검증을 차례로 수행:

### 4-A. 모션 메뉴 — 추가된 19 페이지 확인

1. **⌘3** → Motion Studio 진입
2. 왼쪽 사이드바 "동작 목록" 스크롤. 다음 페이지가 보여야 함:
   - **보행 테스트 1 — 자세 유지 (2초)** (slot 50)
   - **보행 테스트 2 — 팔만 흔들기 (다리 정지)** (slot 51)
   - **보행 테스트 3 — 무릎 3° 굽힘 (조정 squat)** (slot 52)
   - **보행 테스트 4 — 우측 hip sway (발 고정)** (slot 53)
   - **보행 테스트 5 — 좌측 hip sway (발 고정)** (slot 54)
   - **보행 테스트 6 — 앞뒤 lean ±2° (IMU baseline)** (slot 55)
   - **거북목 케어 — 목 좌우 회전** (slot 60), **목 끄덕임** (slot 61)
   - **어깨 케어 — 양팔 위로 스트레치** (slot 62)
   - **허리 케어 — 좌우 트위스트** (slot 63)
   - **어깨 운동 — 만세 × 3회** (slot 64)
   - **다리 케어 — 우측 런지** (slot 65)
   - **환영 인사**, **수락 (OK)**, **작별 인사**, **출발 신호**, **환호** (slot 70~74)
   - **머리 긁기**, **흥분 표현**, **말하기 제스처**, **감사 표현** (slot 80~83)

3. "보행 테스트 1" 선택 → ⌘↵ (재생) → 중앙 3D 뷰의 로봇이 2 초간 walkReady 자세 유지 후 종료.
4. "거북목 케어 — 목 좌우 회전" 선택 → 재생 → 머리만 좌우로 회전, 다리 정지.

### 4-B. Walk Lab — 안전 색대역 슬라이더 확인

1. **⌘4** → Walk Lab 진입
2. 사이드바 상단 **"정비 스탠드에 거치됨"** 체크박스 ON
3. **"고급 — 슬라이더 조정"** 토글 ON
4. 다음 슬라이더 6 개가 보여야 함:
   - 보폭 (앞) — 트랙: 좌 녹색 → 중간 노랑 → 우 빨강 그라데이션
   - 측면 보폭 — 트랙: 양 끝 빨강, 중앙 녹색 (bidirectional)
   - 회전 — 동일 bidirectional 패턴
   - 주기 (작을수록 빠름) — 트랙이 **좌 빨강 → 우 녹색** (inverted)
   - 발 들기 높이 — 트랙이 양쪽 빨강, 30~50 중간 녹색 (sweet spot)
   - 균형 게인 — 동일 sweet spot 패턴
5. 슬라이더 위에 **"낙상 위험 0/100 안전"** 게이지 표시.

### 4-C. 안정성 점수 + smart-clamp 인터랙션

1. "보폭 (앞)" 슬라이더를 천천히 우측으로 드래그.
   - 0~20 mm 영역: thumb 녹색, 점수 < 30
   - 20~30 mm: thumb 노랑, 점수 30~60
   - 30+ mm: thumb 빨강, 점수 60+
   - 메시지 영역에 "보폭 XX mm — MX-28 무릎/발목 부하 가중" 표시
2. 슬라이더를 35 mm 까지 올린 후, "주기" 슬라이더를 450 으로 내린다.
   - 보폭 슬라이더의 우측에 **빨간 패턴 오버레이**가 확장됨 (smart-clamp = 25 mm 가 됨)
   - 보폭이 25 로 자동 클램프
3. **Option (⌥) 키 누른 채로** 슬라이더 드래그 → 5 배 미세 조정. 값 표시 위에 "⌥ 미세" 배지 등장.
4. **"안전 한도 해제"** 토글 ON → smart-clamp 빨간 영역 사라짐, 슬라이더가 전체 범위 사용 가능.
5. 보폭 45 + 주기 400 + 균형 게인 0 까지 올림 → 점수가 **80 이상 (critical)** → 다음 banner 표시:
   > "낙상 위험 점수 XX/100 — 시작 차단. 슬라이더 값을 줄이거나 안전 한도 해제를 끄세요."
6. 이 상태에서 사이드바의 "천천히 걷기" 버튼 클릭 → 아무 일도 안 일어나야 함 (start gate 차단).

### 4-D. 빠른 reset 동작

1. "권장 안전 값으로" 버튼 클릭 → 모든 슬라이더가 안전 값으로 (보폭 15 / 주기 700 / 발 들기 40 / 게인 1.0).
2. "0 초기화" 버튼 클릭 → 보폭/측면/회전 0, 주기 600.

---

## 5. (선택) 실 로봇에 walk-progression-v1.bin 적용

> **⚠ 위험.** [`docs/walk-lab/WALK_PROGRESSION_TEST.md`](../walk-lab/WALK_PROGRESSION_TEST.md) 의
> "사전 준비" 5 체크리스트 (백업 / 거치 / 배터리 / 펌웨어 / offset) 통과 후에만.

```sh
# 5-1. 로봇 IP 확인 후 motion_4096.bin 백업
ssh darwin@<ROBOT_IP> "cp /darwin/Data/motion_4096.bin \
    /darwin/Data/motion_4096.bin.bak.\$(date +%Y%m%d-%H%M%S)"

# 5-2. 새 파일 전송 (기존 파일과 분리해서 별도 이름)
scp motions/test/walk-progression-v1.bin \
    darwin@<ROBOT_IP>:/darwin/Data/walk-progression-v1.bin

# 5-3. SSH 접속 후 action_editor 로 페이지 110~115 검증
ssh darwin@<ROBOT_IP>
cd /darwin/Linux/project/action_editor
sudo ./action_editor /darwin/Data/walk-progression-v1.bin
# action_editor> page 110
# action_editor> play   <- 2 초 walkready hold
# action_editor> page 111
# action_editor> play   <- 팔만 흔들기
# action_editor> page 115
# action_editor> play   <- 가장 위험 — 손 잡고
```

각 페이지의 **합격 기준** (IMU pitch/roll 임계, 모터 온도 등) 은
[`docs/walk-lab/WALK_PROGRESSION_TEST.md §5`](../walk-lab/WALK_PROGRESSION_TEST.md) 참조.

---

## 6. 결과 보고 (실패한 단계가 있다면)

다음 정보를 그대로 복사해 알려주시면 즉시 픽스 가능:

```sh
# 6-1. 어느 단계에서 실패했는지 (§2 빌드, §3 테스트, §4-A/B/C/D 실행)

# 6-2. 빌드 / 테스트 에러 전체 (마지막 50 줄)
swift test --package-path app/ui/DarwinForge 2>&1 | tail -50

# 6-3. swift / rust 버전
swift --version; rustc --version; sw_vers

# 6-4. (Walk Lab UI 가 이상하면) 스크린샷 + 어떤 슬라이더에서 어떤 동작이 어땠는지
```

---

## 7. PR #3 자동 모니터링 (옵션)

본 Claude 세션에 PR 활동 (리뷰 / CI / 코멘트) 이 도착하면 자동으로 응답하도록 이미
`subscribe_pr_activity` 가 활성화되어 있습니다. 사용자 측에서는 별도 작업 불필요 —
PR 페이지에 댓글 달거나 리뷰 요청 시 webhook 으로 본 세션에 전달됩니다.

세션을 닫고 새 Claude Code 인스턴스에서 다시 이어가려면:
```
/resume   # 세션 목록에서 01FoU9Mr9BdwrQjKBEFdBQEg 선택
```
또는 PR #3 페이지에서 사용자 본인 또는 다른 리뷰어가 코멘트 → webhook 자동 알림.

---

## 부록 A — 변경 파일 요약 (PR #3 기준)

| 종류 | 파일 | 라인 |
|------|------|------|
| 신규 | `app/ui/DarwinForge/Sources/ForgeCore/WalkStabilityPredictor.swift` | ~240 |
| 신규 | `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/SafetyBandedSlider.swift` | ~230 |
| 신규 | `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/AdvancedSlidersPanel.swift` | ~260 |
| 신규 | `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/ReferenceMotionLibrary.swift` | ~310 |
| 신규 | `app/ui/DarwinForge/Tests/ForgeCoreTests/WalkStabilityPredictorTests.swift` | ~140 |
| 신규 | `motions/test/walk-progression-v1.{bin,json}` + `scripts/research/generate_walk_test_motion.py` | — |
| 수정 | `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift` | +56 -16 |
| 수정 | `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift` | +12 -28 |
| 수정 | `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/MotionStudioView.swift` | +10 |
| 수정 | `app/ui/DarwinForge/Tests/DarwinForgeUITests/StarterMotionLibraryTests.swift` | +32 |
| 자료 | `research/community/` (4 클론) + `motions/external/` (카탈로그) | 거대 |
| 문서 | `docs/walk-lab/WALK_PROGRESSION_TEST.md`, `docs/walk-lab/COMMUNITY_REFERENCES.md`, `docs/motion-format/EXTERNAL_MOTION_LIBRARIES.md` | — |

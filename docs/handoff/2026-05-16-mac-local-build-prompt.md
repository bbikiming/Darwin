# Mac 로컬 빌드 + 실행 프롬프트

PR #25 (`feature/v1.1-walklab-fall-prevention`) 를 Mac 로컬에서 받아 빌드/실행 / 검증할 때 Claude Code 또는 다른 AI assistant 에게 전달할 단일 프롬프트.

---

## 사용 방법

1. Mac 에서 DarwinForge repo 가 이미 클론된 디렉터리로 이동
2. Claude Code 또는 다른 assistant 에 아래 `프롬프트 본문` 전체를 복사/붙여넣기
3. assistant 가 단계별 실행

---

## 프롬프트 본문 (복사하여 사용)

```
## 작업 요청 — DarwinForge PR #25 Mac 로컬 빌드 + 실행 + 검증

### 배경

`bbikiming/Darwin` 의 PR #25 (branch: `feature/v1.1-walklab-fall-prevention`) —
v1.1 Walk Lab Fall Prevention + Monitoring Dashboard + Design System v1.

이전 세션에서 35+ commit 작업 (7,649 insertions, 13 handoff docs). 그러나
실 Mac 환경 빌드 / 테스트 미수행. 본 작업은 Mac 환경 도달 후 검증 단계.

### 사전 조건 (이미 충족되었을 것으로 가정)

- macOS 14+
- Xcode 15.4+ (Swift 5.10+ 포함)
- Rust 1.94+ (rustup)
- Python 3.11+, Node 22+, Homebrew
- USB-Serial 드라이버 (실 robot 검증 시 — 빌드만 할 거면 X)

### 단계 1: 환경 준비 + branch checkout

```sh
cd /Users/$USER/path/to/Darwin     # 사용자 환경 맞춰 조정
git fetch origin
git checkout feature/v1.1-walklab-fall-prevention
git pull origin feature/v1.1-walklab-fall-prevention
git log --oneline -5
```

확인: 최신 commit 이 `003d210` (macro review) 또는 그 이후인지.

### 단계 2: 도구 점검

```sh
bash scripts/bootstrap-tools.sh
```

빠진 도구가 있으면 brew install 안내됨. 모두 OK 이어야 진행.

### 단계 3: Rust 코어 + Swift 빌드 (한 번에)

```sh
bash scripts/build-mac.sh -u --swift
```

- `-u`: universal binary (arm64 + x86_64)
- `--swift`: Rust 코어 빌드 후 swift build 까지

빌드 결과:
- `app/core/target/release/libforge_core.a` 생성
- `app/ui/DarwinForge/Vendor/CForgeCore/{include,lib}` 채움
- `app/ui/DarwinForge/.build/...` Swift 산출물

**Compile error 0** 이어야 진행. 에러 시 즉시 보고 — 본 PR 의 35+ commit
중 어디가 깨졌는지 추적 필요.

### 단계 4: Rust 회귀 테스트

```sh
make test
```

또는

```sh
cd app/core
cargo test --workspace
```

기존 Rust 회귀가 깨졌는지 확인. **본 PR 은 Rust 변경 0** — 통과해야 정상.

### 단계 5: Swift 회귀 테스트 (PR #25 의 핵심)

```sh
cd app/ui/DarwinForge
swift test --filter WalkLabFallPreventionTests
```

기대: 35+ 테스트 통과:
- Stage 1 (IMU wire-up): 4
- Stage 2 (다단계 임계): 5
- Stage 3 (FallPredictor): 10
- Stage 4 (BalanceCorrector): 11
- Monitoring (timeline + events): 7
- L6 Thermal: 4
- 시인성 (color/icon/animation tokens): 4
- 시맨틱 alias: 1
- NaN/Inf 방어: 1
- Phase C corrector identity: 1
- Emergency event emission: 1
- 단위 변환 (mm/m, deg/rad): 1
- AllNaN samples → zero: 1
- Intensity clamp: 1
- L3 boundary: 1

추가 50-시나리오 매트릭스:

```sh
swift test --filter WalkLab50ScenarioMatrixTests
```

기대: 50 cell × 6 회귀 cluster = 300+ assertion 통과.

### 단계 6: SwiftLint advisory (선택)

```sh
brew install swiftlint    # 없으면
cd /Users/$USER/path/to/Darwin
swiftlint lint --quiet
```

`.swiftlint.yml` 의 5 custom rule 위반 경고 확인 (custom rules — 본 PR 의
monitoring 영역은 깨끗해야 함).

### 단계 7: 앱 실행 (Walk Lab 동작 확인)

```sh
make run
```

또는 직접:

```sh
cd app/ui/DarwinForge
swift run DarwinForgeApp
```

앱 실행 후 검증:

#### 7-1. Walk Lab 진입
- 메뉴 → `⌘4` (워크 랩) → WalkLabView 열림
- 사이드바: 8 preset (idle, march, slowWalk, normalWalk, fastWalk, turnLeft, turnRight, jog)

#### 7-2. Monitoring dashboard 토글
- detail panel 상단 "Fall Prevention 모니터링" bar
- 펼치기 버튼 클릭 (또는 ⌘⇧M)
- 펼침 시 5 section 표시:
  - Hero status banner (큰 icon + state.label + tilt + IMU/모터 source pill)
  - 6-Layer status grid (L1-L6 tile)
  - Time-series 3 sparkline (Roll/Pitch/Score)
  - Corrector deltas + ramp progress
  - Event log

#### 7-3. 영구성 검증
- ⌘⇧M 토글 → 펼침 상태
- 앱 종료 (⌘Q)
- 다시 실행 → monitoring 펼침 상태 복원 확인 (`@AppStorage` 동작)

#### 7-4. 메뉴바 통합
- "보기" 메뉴 → "Fall Prevention 모니터링" 항목 (⌘⇧M 단축키 명시)

#### 7-5. 시각 검증 (Xcode Preview)
- Xcode 에서 `FallPreventionMonitor+Previews.swift` 열기
- Canvas 활성 (⌘⌥↩)
- 10 시나리오 (정상/경고/위험/Corrector ON/이벤트 로그/4 폭/Dark/Dynamic Type)
  모두 의도된 모습 확인

#### 7-6. Accessibility (선택)
- 시스템 설정 → 손쉬운 사용 → VoiceOver 켜기 (⌘F5)
- Walk Lab → monitoring 펼침 → 각 element 라벨 확인:
  - Hero: "안전 상태 정상, 최대 기울기 0.0도"
  - Layer tile: "L3 IMU Tilt 0.0° — 15/22/28/30° 5단계"
  - Sparkline: "Roll 시계열 — 현재 +0.0°, 트렌드 평탄"
  - Event row: "HH:mm:ss sessionStart — 보행 시작 — 제자리"

#### 7-7. Reduce Motion (선택)
- 시스템 설정 → 손쉬운 사용 → 디스플레이 → Reduce Motion ON
- danger 상태 시뮬 (어려움 — sim 모드에서 28° 도달 어려움)
- Hero banner 의 emergency pulse animation 가 disable 되었는지

#### 7-8. Increase Contrast (선택)
- 시스템 설정 → 손쉬운 사용 → 디스플레이 → 대비 늘리기 ON
- `DFColor.severe / .danger / .success` 등이 더 진한 톤으로 자동 변환

### 단계 8: 발견 issue 정리

각 단계에서 발견된 문제:

1. **Compile error**: 즉시 보고. 이전 commit chain 의 어느 라인이 문제인지 추적.
2. **Test failure**: 어느 테스트가 실패했는지 + assertion message + 예상 vs 실제.
3. **시각 이상**: Xcode Preview 의 어떤 시나리오가 의도와 다른지.
4. **Runtime crash**: stack trace + 재현 시나리오.
5. **Accessibility 미동작**: VoiceOver 가 못 읽거나 잘못 읽는 element.

### 단계 9: 결과 보고

다음 정보로 PR #25 에 코멘트 추가:

- Mac 환경: macOS X.X, Xcode X.X, Swift X.X
- 단계 3 (build-mac.sh) 결과: ✓ / ✗
- 단계 5 (swift test) 결과: passed / failed (개수 + 실패 list)
- 단계 7 (앱 실행) 시각 확인: 5 section 모두 OK / 일부 이슈
- 발견 issue list (priority + description)

### 안전 가드 (실 robot 미연결 가정)

본 작업은 **시뮬 모드 + 빌드 검증만**. 실 robot HIL 검증은 별도:
- robot 연결 + 정비 스탠드 거치 + cradle 확인
- 점진 시나리오: walkReady → 천천히 보행 → 빠르게 보행
- Stage 4 corrector 토글: **default OFF 유지 권장**. 활성 시 입회 필수.

### 작업 우선순위

1. **단계 3 (빌드)** 통과 — blocker
2. **단계 5 (swift test)** — 회귀 통과 확인
3. **단계 7 (앱 실행)** — 시각 + UX 검증
4. **단계 6 (SwiftLint)** — 선택 (advisory)
5. **단계 7-5~7-8 (a11y)** — 선택 (Mac 환경 의존)

각 단계 완료 시 즉시 PR #25 코멘트 추가 — 다음 작업자가 stage 별 상태 추적 가능.

빌드 / 테스트 / 실행 부터 시작.
```

---

## 추가: 빠른 명령 cheat sheet

```sh
# 한 번에 빌드 + 실행
make run

# 또는 단계별:
bash scripts/bootstrap-tools.sh         # 도구 점검
bash scripts/build-mac.sh -u --swift    # Rust + Swift universal
cd app/ui/DarwinForge && swift test     # 회귀 테스트
swift run DarwinForgeApp                # 앱 실행
```

## 디버깅 명령

```sh
# Swift 컴파일 에러 분석
cd app/ui/DarwinForge
swift build 2>&1 | head -50

# 특정 테스트만
swift test --filter WalkLabFallPreventionTests/testL3GateThresholdBoundaryConsistency

# Rust 코어만 (Swift 의존 없이)
cd app/core
cargo test --workspace

# 클린 빌드
make clean
make app
```

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `cargo: command not found` | Rust 미설치 | `curl https://sh.rustup.rs -sSf \| sh` |
| `swift: command not found` | Xcode 미설치 | App Store → Xcode |
| `error: missing forge_core.h` | Vendor/ 미생성 | `bash scripts/build-mac.sh` (Rust 빌드 우선) |
| `Cannot find type 'DFIcon'` | branch outdated | `git pull origin feature/v1.1-walklab-fall-prevention` |
| `Localizable.strings 처리 X` | Package.swift cache | `cd app/ui/DarwinForge && rm -rf .build && swift build` |
| App 실행 후 dock 아이콘 없음 | NSApp activation | 코드의 AppDelegate.applicationDidFinishLaunching 가 처리 |

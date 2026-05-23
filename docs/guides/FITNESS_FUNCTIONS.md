# Architectural Fitness Functions

> 사이클 270 (V270-2) 도입 — Ford / Parsons / Kua,
> *Building Evolutionary Architectures* §2 에서 정의한 fitness function 의
> DarwinForge 적용 가이드.

## 1. 정의

**Fitness function**: 아키텍처 특성을 자동으로 측정·강제하는 객관적 함수.
사람의 코드 리뷰에 의존하는 대신, 매 커밋/CI 에서 자동 검증 → 진화적 아키텍처
의 핵심 인프라.

본 가이드는 DarwinForge 의 fitness function 5종을 정의하고, 각각의 실행
방법·정책·향후 계획을 명시한다.

## 2. 활성 functions

| # | Function | Type | Status | 실행 |
|---|---|---|---|---|
| 1 | File LOC ceiling (<= 800) | atomic / static | active | `scripts/fitness-check.sh` |
| 2 | SwiftLint custom rules (Harness.shared, DFSpace/DFColor 토큰 등) | atomic / static | active | `swiftlint lint --strict` (scripts/fitness-check.sh §2) |
| 3 | Timing baseline (IMU/Walk P99 < 5ms) | atomic / dynamic | infra-only (수동) | Instruments + `app/ui/DarwinForge/docs/architecture/timing-baseline.md` |
| 4 | Code coverage threshold (>= 80%) | atomic / static | partial | XCTest cov plist (CI 통합 필요) |
| 5 | Mock Bus 통합 test gate (1962 tests) | holistic / static | active | `swift test` (사이클 255+) |

### 2.1 File LOC ceiling

**룰**: 모든 Swift source file 은 800 줄 이하.

**근거**: `claude-forge/rules/coding-style.md` "MANY SMALL FILES > FEW LARGE FILES"
+ `golden-principles.md` §5 "작은 파일, 작은 함수" — 파일 800줄, 함수 50줄,
중첩 4단계 한계.

**정책** (점진 enforcement):

- 신규 file 의 첫 commit 이 >800 LOC → hard fail (exit 1).
- 기존 grandfathered file (Wave 4 분할 진행 중) → warning only (exit 0).
- Grandfathered list: `scripts/fitness-check.sh` 상단 array.

**Grandfathered (사이클 270 채택 시점, 15건)**:

```
WalkLab/WalkLabSession.swift                2417
ConnectionStore.swift                       2237
Connection/ConnectionWizard.swift           1650
Expert/WalkDiagnostics/WalkDiagnosticsView.swift  1592
WalkLab/WalkLabView.swift                   1284
Connection/RobotSetupCommand.swift          1240
WalkLab/Components/FallPreventionMonitor.swift    1222
RootView.swift                              1206
Logging/Harness/HarnessInspectorView.swift  1138
Studio/StudioView.swift                     1065
Visualization/RobotScene3D.swift            1055
DesignSystem/DesignTokens.swift              967
WalkLab/Learning/WalkDataView.swift          898
WalkLab/Components/SceneSpeedometerOverlay.swift  864
Pilot/RemotePilotView.swift                  858
```

Wave 4 분할 완료 시 본 list 에서 제거 → 자동으로 hard-fail 대상이 됨.

### 2.2 SwiftLint custom rules

**룰**: `.swiftlint.yml` 정의된 모든 rule (project + custom) 통과.

**핵심 custom rules**:

- `df_no_harness_shared_direct_access` / `df_no_harness_shared_assignment`:
  Wave 3 Phase 3.4 (사이클 115) Harness DI migration gate.
  `Harness.shared` 직접 접근 차단. `@Environment(\.harness)` 또는
  init injection 사용 강제. 5건 예외 (Harness.swift, LiveHarness.swift 등).
- `df_no_raw_padding` / `_spacing` / `_corner_radius` / `_opacity`:
  Design system 토큰 강제 (DFSpace / DFRadius / DFOpacity).
- `df_prefer_dfcolor_over_system_named`: `.foregroundStyle(.red)` 등 system
  named color 차단 → `DFColor.danger` 등 semantic 토큰 사용.

**실행**:

```bash
swiftlint lint --strict   # warning 만 있어도 exit 1
```

`fitness-check.sh` 단계 2 가 자동 호출. SwiftLint 미설치 시 skip + 안내.

### 2.3 Timing baseline (infra only)

**룰**: `imu_iter` / `walk_tick` P99 < 5ms.

**현황**: `app/ui/DarwinForge/docs/architecture/timing-baseline.md` 에 baseline
프로토콜 정의됨. 측정은 Instruments 수동 + 결과 JSON 을
`docs/architecture/baselines/imu_iter_<date>.json` 에 archive.

**향후**: XCTest `measureMetrics` 기반 자동화 → CI 단계 추가 (사이클 미정).

### 2.4 Coverage threshold

**룰**: line coverage >= 80% (golden-principles.md §3 TDD).

**현황**: `swift test --enable-code-coverage` 로 plist 생성. 임계값 자동 비교
스크립트 (`scripts/coverage.sh`) 는 미구현.

**향후**: `xcrun llvm-cov export ... | jq '.data[0].totals.lines.percent'` 로
숫자 추출 → 80% 미만 시 fail.

### 2.5 Mock Bus 통합 test gate

**룰**: `swift test` 전체 통과 (사이클 270 기준 1962 tests).

**현황**: CI 의 swift test step 이 이미 enforce 중. 본 fitness function 의
"holistic" type 대표 — 단위 함수 단일 측정으로는 잡히지 않는 system-level
correctness 를 보장.

## 3. 설치 (개발자 머신)

### Pre-commit hook 활성화

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin
ln -s ../../scripts/fitness-check.sh .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

이후 `git commit` 시 자동 실행. Fail 시 commit 차단.

### 검증

```bash
bash scripts/fitness-check.sh                  # staged file 만 검사 (pre-commit mode)
FITNESS_MODE=all bash scripts/fitness-check.sh # 전체 source 검사 (CI mode)
```

## 4. Override (긴급 시)

```bash
git commit --no-verify   # NOT recommended — hotfix 만
```

`--no-verify` 사용 시 반드시 후속 PR 에서 issue 등록 + 사이클 기록.

## 5. CI 통합 (향후)

GitHub Actions workflow (`.github/workflows/`) 에 push trigger step 추가:

```yaml
- name: Architectural fitness check
  run: FITNESS_MODE=all bash scripts/fitness-check.sh
```

이로써 개발자가 hook 을 설치하지 않아도 main branch protection 으로
fitness function 이 enforce 됨.

## 6. 참고 문헌

- Ford, N., Parsons, R., Kua, P. (2017). *Building Evolutionary Architectures:
  Support Constant Change.* O'Reilly.
- `claude-forge/rules/coding-style.md` — File Organization (800 LOC ceiling)
- `claude-forge/rules/golden-principles.md` §5 — 작은 파일, 작은 함수
- `app/ui/DarwinForge/docs/architecture/timing-baseline.md` — P99 5ms 룰
- `.swiftlint.yml` — custom rule 정의

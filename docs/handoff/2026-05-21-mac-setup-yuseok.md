# Mac 로컬 세팅 — /Users/yuseok_air/Documents/robotis

PR #25 merge 후 v1.11.23 상태의 DarwinForge 를 Mac 에 세팅 + 빌드 + 실행.

---

## 1단계: 디렉터리 생성 + 클론

Mac terminal 에서 한 줄씩 실행:

```sh
# 디렉터리 생성
mkdir -p /Users/yuseok_air/Documents/robotis
cd /Users/yuseok_air/Documents/robotis

# Clone (이미 있으면 skip — 2단계 로)
git clone https://github.com/bbikiming/Darwin.git
cd Darwin

# 최신 main 으로
git checkout main
git pull origin main
git log --oneline -5
```

**확인**: 최신 commit 이 `c8f39dc` (v1.11.23 install Codex final fix) 또는 그 이후.

---

## 2단계: 이미 클론된 경우 — 최신 동기화

```sh
cd /Users/yuseok_air/Documents/robotis/Darwin

git fetch --all --prune
git checkout main
git pull origin main
git log --oneline -5
```

---

## 3단계: 사전 도구 점검

```sh
bash scripts/bootstrap-tools.sh
```

요구사항:
- macOS 14+
- Xcode 15.4+ (Swift 5.10+)
- Rust 1.94+ (rustup)
- Python 3.11+, Node 22+, Homebrew

빠진 도구 있으면 안내 따라 설치 후 다시 실행.

---

## 4단계: 한 번에 빌드 + 실행

```sh
make run
```

또는 단계별:

```sh
# Rust 코어 + Swift universal 빌드
bash scripts/build-mac.sh -u --swift

# Swift 회귀 (646 tests)
cd app/ui/DarwinForge
swift test

# 앱 실행
cd /Users/yuseok_air/Documents/robotis/Darwin
make run
```

---

## 5단계: 앱 설치 (선택)

```sh
bash scripts/install-app.sh
```

→ `/Applications/DarwinForge.app` 설치. Spotlight 에서 "DarwinForge" 검색 가능.

---

## 6단계: 확인할 기능 (v1.11.23 최신)

### Walk Lab (⌘4)
- **Fall Prevention Monitor** (⌘⇧M) — 5-section dashboard
- **Boeing PFD HUD** — 3D 우상단 7-section overlay (NEW v1.11.20-21)
- **Live Gyro Panel** — 진입 즉시 실시간 자이로 (NEW v1.11.17)
- **Static IMU Calibration** — 5축 정적 캡처 진단 (PR #26)

### 안전 가드 (PR #26 강화)
- ⚠️ **hybridBA + apply / v110Experimental + apply 조합 `.blocked`** — 실 robot fall 데이터 기반
- ✓ robotisOriginal + Pure preset 만 `.safe`
- ✓ L3 50° hard gate × 3 sample hysteresis (150ms)
- ✓ Warning 35°+ → cancelWalkCycle 실 motor 적용
- ✓ Corrector freshness gate (250-500ms) + IMU stale 자동 OFF

### 새 기능 (PR #37-#40)
- **DFLog** OSLog (subsystem "com.darwinforge", 6 categories)
- **DFStateComponents** (LoadingState / ErrorState / InlineMessage)
- **MJPEG Camera streaming** (Pilot)
- **GitHub Actions CI** workflow

---

## 안전 가드 (실 robot 검증 시)

⚠️ **PR #26 의 실 robot fall 데이터 입증**:
- hybridBA + apply 조합 → **2.3초 내 fall** (peak -37.8°)
- v110Experimental + apply 조합 → **1.4초 내 fall** (peak -35.5°)
- → 모두 `.blocked` 격상됨

**권장 절차**:
1. **첫 실행**: sim 모드 + 모니터 dashboard 만 확인 (실 robot 미연결)
2. **실 robot 연결**: cradle 거치 + 정비 스탠드 + 입회
3. **점진 보행**: walkReady → 천천히 (slowWalk) → 보통 (normalWalk)
4. **Corrector 활성 금지**: `.blocked` 조합은 시도 X. `.safe` (robotisOriginal + Pure) 만.

---

## 트러블슈팅

| 증상 | 해결 |
|---|---|
| `cargo: command not found` | `curl https://sh.rustup.rs -sSf \| sh` |
| `swift: command not found` | App Store → Xcode 설치 |
| `error: missing forge_core.h` | `bash scripts/build-mac.sh` (Rust 우선) |
| Swift 5.9 strict concurrency 경고 | `swift --version` 확인. Xcode 15.4+ 필요 |
| `.build cache` 충돌 | `cd app/ui/DarwinForge && rm -rf .build && swift build` |
| `App 실행 후 dock 아이콘 없음` | 정상 — AppDelegate.applicationDidFinishLaunching 자동 처리 |

---

## 디렉터리 구조

```
/Users/yuseok_air/Documents/robotis/Darwin
├── app/
│   ├── core/                       # Rust workspace
│   │   ├── forge-core/             # 핵심 control logic
│   │   ├── forge-ffi/              # C-ABI bridge
│   │   └── forge-cli/
│   └── ui/DarwinForge/             # Swift Package
│       ├── Sources/
│       │   ├── DarwinForgeApp/     # @main App
│       │   ├── DarwinForgeUI/      # SwiftUI views
│       │   └── ForgeCore/          # Swift wrapper
│       ├── Tests/
│       └── Vendor/CForgeCore/      # build-mac.sh 자동 생성
├── scripts/
│   ├── build-mac.sh                # 통합 빌드
│   ├── bootstrap-tools.sh          # 도구 점검
│   ├── install-app.sh              # /Applications/ 설치
│   └── run-app.sh
├── motions/                        # 모션 데이터
└── docs/handoff/                   # 작업 핸드오프
```

---

## 즉시 실행 (한 줄)

이미 클론되어 있다면:

```sh
cd /Users/yuseok_air/Documents/robotis/Darwin && git pull origin main && make run
```

처음 시작이라면:

```sh
mkdir -p /Users/yuseok_air/Documents/robotis && \
cd /Users/yuseok_air/Documents/robotis && \
git clone https://github.com/bbikiming/Darwin.git && \
cd Darwin && \
bash scripts/bootstrap-tools.sh && \
make run
```

# Mac에서 DarwinForge 실행 가이드

> macOS Sonoma+ / Apple Silicon 또는 Intel. ROBOTIS DARwIn-OP / OP2 둘 다.

## 빠른 시작 (한 줄)

```sh
make run     # 도구 점검 → cargo build → swift build → swift run DarwinForgeApp
```

자세한 단계는 아래 §1..§6 참조.

## 1. 일회성 사전 준비

### 도구 설치

| 도구 | 설치 |
|------|------|
| Xcode 15.4+ + Command Line Tools | App Store + `xcode-select --install` |
| Rust 1.78+ | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| (선택) Homebrew | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |

도구 점검:
```sh
make doctor    # 또는 bash scripts/bootstrap-tools.sh
```

### USB-Serial 드라이버 (CM-730/740)

```sh
bash scripts/check-mac-drivers.sh
```

* macOS Sequoia/Sonoma는 **Apple In-Kernel FTDI 드라이버를 우선** 사용.
* 안 보이면 시스템 설정 → 개인정보 보호 및 보안 → 시스템 확장 → 허용.
* 자세한 내용: [`harness/shared/mac-driver-setup.md`](../harness/shared/mac-driver-setup.md).

## 2. 빌드

```sh
make mac           # Apple Silicon만 (현재 호스트)
make mac-universal # arm64 + x86_64 universal
make app           # mac + swift build
make run           # mac + swift run DarwinForgeApp (앱 실행)

# 또는 직접:
bash scripts/build-mac.sh -u --swift
```

스크립트가 차례로 수행:

1. `cargo build --release -p forge-core -p forge-ffi -p forge-cli`
2. `cbindgen`으로 `forge_core.h` 자동 생성 (build.rs)
3. `Vendor/CForgeCore/lib/libforge_core.a` + `include/{forge_core.h, module.modulemap}` 생성
4. (옵션) `swift build` 실행

## 3. 실행

### CLI (`forge`)

Rust 코어만 사용 — Swift 미설치도 OK:

```sh
./app/core/target/release/forge ports                  # USB 포트 나열
./app/core/target/release/forge list-joints            # 16개 관절 표
./app/core/target/release/forge ping --port /dev/cu.usbserial-XXXX
./app/core/target/release/forge scan --port ... --range 1-20
./app/core/target/release/forge board --port ...       # 모델/전압/버튼
./app/core/target/release/forge joint set --port ... --id 19 1900
./app/core/target/release/forge joint state --port ... --id 19
./app/core/target/release/forge joint torque --port ... --target all --enable off
./app/core/target/release/forge joint estop --port ...
./app/core/target/release/forge motion import sample.mtn
./app/core/target/release/forge walk --x 0.04 --cycles 1
./app/core/target/release/forge strategy --ball=found
```

### SwiftUI 앱

```sh
swift run --package-path app/ui/DarwinForge DarwinForgeApp
```

또는 Xcode에서 열기:
```sh
xed app/ui/DarwinForge/Package.swift
```

앱 화면 (왼쪽 사이드바 + 디테일):

| 탭 | 내용 |
|-----|------|
| **Board Status** | CM-730/740 모델 / 펌웨어 / 배터리 전압 (1 Hz 폴링) |
| **Joint Control** | 16개 관절 좌측 리스트 + 우측 슬라이더 / 토크 / e-stop |
| **Motion Library** | `.mtn` 파일 import → JSON ↔ .mtn round-trip preview |
| **Walk Sim** | 워크 엔진 시뮬레이션 (실 모터 명령 X — 발 궤적만) |
| **Strategy FSM** | 5상태 결정성 전이 시뮬레이션 |

전역 단축키:
- `⌘⇧.` — 모든 관절 토크 OFF (소프트 e-stop)

## 4. 실기기 첫 연결 흐름

> 시작 전: [`harness/shared/safety.md`](../harness/shared/safety.md) "매번" 체크리스트 6개.

1. **로봇을 정비 스탠드(cradle)에 거치**.
2. e-stop 토글 OFF 상태에서 LiPo 연결, 안정성 확인 후 ON.
3. Mac에 USB 연결 → `forge ports`로 디바이스 노드 확인.
4. DarwinForge.app 실행 → 사이드바 Connection 패널에서 포트 선택 → Connect.
5. **Board Status** 탭에서 모델 (CM-730 / CM-740) 자동 식별, 전압 확인.
6. **Joint Control** 탭에서 한 관절씩 토크 ON → 슬라이더 조작.
   - **다리 관절(L_HIP_*, L_KNEE, R_HIP_*, R_KNEE)은 cradle 미거치 시 토크 ON 절대 금지**.
7. 종료 시 e-stop 단축키(⌘⇧.) → 토글 OFF → LiPo 분리.

## 5. 빌드 후 스모크 테스트 (실기기 없이)

```sh
bash scripts/smoke-test.sh
```

확인 항목:
- forge --version, list-joints, ports
- motion .mtn ↔ JSON round-trip (의미 있는 데이터 100% 일치)
- walk simulation 1 cycle
- strategy FSM 6 step

모두 통과하면 실기기 검증 단계로 진입 가능.

## 6. 트러블슈팅

| 증상 | 해결 |
|------|------|
| `swift build` 실패: `cannot find 'fc_*' in scope` | `make mac`(또는 `bash scripts/build-mac.sh`)를 먼저 실행 — Vendor/CForgeCore가 비어있음 |
| `swift run` 실패: `Library not loaded: libforge_core` | static link이므로 일반 발생 X. 혹시 dylib 모드로 바꿨다면 `DYLD_LIBRARY_PATH` 설정 |
| 포트 목록이 비어 있음 | 케이블 / CM-730 전원 / FTDI 드라이버 시스템 확장 허용 확인 |
| ping ID 200 timeout | baud 1 Mbps 확인, FTDI latency 1 ms 설정 (`mac-driver-setup.md`) |
| 관절 슬라이더 응답 X | 첫 동작 전 토크 ON 필요 |
| 배터리 전압 < 9.5 V 경고 | LiPo 충전 (cell당 < 3.3 V면 즉시 중지) |
| `forge` 빌드 실패: cbindgen | `cargo install cbindgen --locked` 후 재시도 |
| **3D 뷰포트에 로봇이 안 보이고 바닥만 렌더** | 로봇 STL 메시(`Resources/Meshes/*.stl`)는 `.gitignore` 대상이라 fresh clone / git worktree 에는 없다. `bash scripts/sync-meshes.sh` 실행(또는 `build-mac.sh`/`build-app.sh` 사용 — 빌드 시 자동 동기화). SSOT = `vendor/robotis-op2-common/meshes/` |

## 6. 개발 워크플로

```sh
# 코어 코드 수정 (Rust)
$EDITOR app/core/forge-core/src/...
cargo test --manifest-path app/core/Cargo.toml

# UI 수정 (Swift)
$EDITOR app/ui/DarwinForge/Sources/...
bash scripts/build-mac.sh --swift   # 또는 swift run

# 핸드 테스트 (실기기)
bash scripts/harness/probe.sh /dev/cu.usbserial-XXXX
```

코드 수정 시 매번 `bash scripts/build-mac.sh` 가 필요 — Vendor/CForgeCore의 .a를 새로 만든다.

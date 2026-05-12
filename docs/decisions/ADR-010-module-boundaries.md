# ADR-010: 모듈 경계 — Rust 코어 vs Swift UI

- Status: Accepted
- Date: 2026-05-09

## Context

Rust+Swift 이원화(ADR-009)에서 두 언어의 책임 분담을 명확히 해야 한다. 잘못 그으면:
- Swift에서 Rust API를 호출할 때마다 unsafe 변환 필요
- 두 언어에서 같은 타입을 중복 정의 (drift 위험)
- 비동기 모델 충돌 (Tokio vs Swift async)

## Decision

### 책임 분담

| 레이어 | Rust (`app/core/`) | Swift (`app/ui/DarwinForge/`) |
|--------|--------------------|--------------------------------|
| 직렬 포트 I/O | ✅ `forge-core::serial` | ❌ |
| Dynamixel 패킷 코덱 | ✅ `forge-core::dynamixel` | ❌ |
| 컨트롤러 (CM-730/740) | ✅ `forge-core::controller` | ❌ |
| 모션 엔진 | ✅ `forge-core::motion` | (UI 호출만) |
| 워크 엔진 | ✅ `forge-core::walk` | (UI 호출만) |
| 비전 (저레벨) | ✅ `forge-core::vision` | (Vision.framework는 Swift 래핑) |
| SQLite | ✅ `forge-core::db` | (Swift FFI) |
| **앱 라이프사이클** | ❌ | ✅ AppKit/SwiftUI |
| **UI 컴포넌트** | ❌ | ✅ |
| **카메라 캡처** | (포맷 변환만) | ✅ AVFoundation |
| **윈도우/메뉴** | ❌ | ✅ |
| **퍼시스턴스 마이그레이션** | ❌ | ✅ (마이그레이션 SQL은 forge-core가 수행) |

### Boundary 매커니즘

**1차 — staticlib + 헤더**:
- `forge-core`를 `crate-type = ["staticlib"]`로 빌드 → `libforge_core.a` + 자동 생성 `forge_core.h`
- Swift Package가 `cSettings.headerSearchPath` + `linkedLibrary("forge_core")`로 임포트
- Swift 코드는 `import CForgeCore` (Swift modulemap)로 사용

**2차 — `swift-bridge` 또는 `uniffi`**:
- 복잡한 타입(struct, enum)을 자동 변환할 때 사용
- 1차에서 부족하면 도입 (Sprint 4 이후 결정)

### 비동기 모델

- Rust 코어는 **synchronous + std::thread** (실시간 루프는 어차피 OS 스레드 단위)
- 또는 Tokio (선택, Sprint 1에서 결정 — 단위 테스트 용이성 우선이면 sync 유지)
- Swift는 `async/await`. FFI 호출은 모두 **synchronous + 별도 Task로 spawn**.

### 데이터 통과

- 작은 값(int, double, enum) — direct C type
- 문자열 — `*const c_char` + Swift에서 `String(cString:)`
- 큰 버퍼 — `*const u8 + len`, Swift는 `Data(bytesNoCopy:)`로 zero-copy
- 복합 객체 — JSON serialize → Swift에서 Codable로 decode

## Consequences

- **긍정**: 양쪽 언어가 자기 강점에 집중. Rust는 실시간·무결성, Swift는 UX.
- **긍정**: Rust 코어는 단독 테스트 가능 (UI 무관).
- **부정**: 같은 도메인 타입(JointID 등)이 두 곳에 존재 — `scripts/sync-types.sh`로 자동 동기화 필요.
- **위험**: FFI 경계에서 panic 발생 시 Swift 측 미정의 동작 — 모든 export 함수는 `catch_unwind`로 보호.

## 액션

- Sprint 1 시작 시: forge-core staticlib 빌드 → Swift Package에서 임포트 (실 동작은 Sprint 2까지)
- Sprint 2: 첫 FFI 호출 (forge-cli ping 결과를 SwiftUI에 전달)
- Sprint 4: swift-bridge 도입 여부 결정

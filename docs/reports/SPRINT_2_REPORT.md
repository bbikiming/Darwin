# Sprint 2 — Live Joint Control

## 요약

`SYNC_WRITE`/`BULK_READ` codec, `JointState`/`JointLimits` 도메인 타입, `JointController` 안전 강제 wrapper, `forge joint set/state/torque/estop` CLI. 35 tests pass.

## 핵심 산출물

### 신규 모듈

- `forge-core/src/dynamixel/sync.rs` — SYNC_WRITE 캡슐화. `Bus::sync_write(addr, len, &[entries])`. BULK_READ는 함수 시그니처 + 응답 N개 수신 (실 디바이스 검증은 Sprint 5).
- `forge-core/src/joint/state.rs` — `JointState`(8 필드: id/goal/present_pos/speed/load/voltage/temp/torque) + `JointLimits` (position_min/max, max_speed_raw, default ±90° = 1024..3072) + `clamp_position()`/`clamp_speed()`.
- `forge-core/src/control/mod.rs` — `JointController`:
  - `set_torque(joint, on)` / `set_torque_many(joints, on)` (SYNC_WRITE 사용)
  - `set_position(joint, raw)` (단일, clamp 적용, **clamp 결과 반환**)
  - `set_positions_many(targets)` (다중 SYNC_WRITE)
  - `read_state(joint)` (3회 READ로 8개 필드 조립)
  - `emergency_stop()` — 모든 관절 토크 OFF, 단일 SYNC_WRITE

### CLI 확장

```sh
forge joint set --port ... --id 19 2048           # HeadPan을 중앙으로
forge joint state --port ... --id 19              # 8개 상태 필드 출력 (V, °C, torque)
forge joint torque --port ... --target all --enable off
forge joint torque --port ... --target 19 --enable on
forge joint estop --port ...                      # 소프트 e-stop
```

### 검증

| 항목 | 결과 |
|------|------|
| `cargo build --workspace` | ✅ |
| `cargo test --workspace` | ✅ **35 / 35 PASS** (Sprint 1 26 + Sprint 2 신규 9) |
| `cargo clippy -- -D warnings` | ✅ |
| `cargo fmt --check` | ✅ |
| `forge --help` | ✅ 6개 서브커맨드 (joint 추가) |
| `forge joint --help` | ✅ 4개 서브액션 |

신규 테스트 9개:
- sync: 2 (encode_sync_write, sync_write_via_bus)
- joint::state: 3 (voltage 변환, position clamp, speed clamp)
- control: 4 (set_position clamp, set_torque_many SYNC, emergency_stop, read_state 조립)

## 자기검증 결과

- [x] 한계 강제 (set_position이 raw 5000 → 3072로 clamp 후 반환)
- [x] SYNC_WRITE 패킷 레이아웃 검증 (FF FF FE LEN 0x83 ADDR LENGTH (ID DATA)+)
- [x] 안전: emergency_stop()이 16개 관절 모두 한 패킷에 OFF
- [x] read_state가 3개 register read를 8필드 struct로 조립
- [x] CLI ergonomics: `--target all` 또는 ID 숫자, `--enable on/off`
- [x] 모든 PUBLIC API에 doc comment

## SwiftUI 측

ADR-009/010 의 결정에 따라 SwiftUI 슬라이더 UI는 Mac에서 Sprint 1·2 누적된 forge-core를 staticlib + header 통해 임포트해 작성. 컨테이너에서는 컴파일 검증 불가 — 사용자 Mac 작업으로 위임. Sprint 3 종료 후 함께 진행.

## Mac에서 검증 (사용자)

```sh
cargo build --release --manifest-path app/core/Cargo.toml

# 로봇 cradle에 거치, e-stop 토글 OFF 상태에서 LiPo 연결, 안정 후 ON

# 한 관절 안전 테스트 (HeadPan):
./app/core/target/release/forge joint torque --port /dev/cu.usbserial-XXXX --target 19 --enable on
./app/core/target/release/forge joint set --port ... --id 19 1500     # 좌측 약간
./app/core/target/release/forge joint set --port ... --id 19 2596     # 우측 약간
./app/core/target/release/forge joint state --port ... --id 19        # 위치/온도 확인
./app/core/target/release/forge joint torque --port ... --target 19 --enable off

# 다리는 cradle 거치 안 됨이라면 절대 토크 ON 금지
```

## Blockers

없음. Sprint 5 walk loop의 BULK_READ 실 동작 검증은 Sprint 5에서.

## 다음 단계

**Sprint 3 — Motion Import/Export** 즉시 자율 시작:
- `forge-core/src/motion/mod.rs`, `motion/page.rs`, `motion/parser.rs`, `motion/json.rs`
- `.mtn` (RoboPlus Action) 텍스트 포맷 파서·라이터 (`docs/motion-format/mtn-format.md`)
- 내부 JSON 표현 (page-format.md)
- round-trip 무손실 보장 단위 테스트
- `forge motion import file.mtn` / `forge motion export id`
- 사용자 fixtures 생성: 3-page 샘플 motion

# Sprint 1 — Connection Layer

## 요약

`forge-core::dynamixel::Bus`, `forge-core::serial::PosixSerial`,
`forge-core::controller::CmController` 구현. `forge` CLI에 `ports`,
`ping`, `scan`, `board` 4개 서브커맨드가 컨테이너에서 실 작동.

## 핵심 산출물

### 신규 모듈

- `forge-core/src/dynamixel/bus.rs` — `Bus<P: SerialPort>` 추상화. `send`/`recv`/`ping`/`read`/`write`/`scan`. timeout 빌더(`with_timeout`).
- `forge-core/src/serial/posix.rs` — `PosixSerial` 어댑터. `serialport` crate 4.7 wrapping. `open(path, baud)`, `list_ports()` (USB만 필터), 1 Mbps 8-N-1.
- `forge-core/src/controller/cm.rs` — `CmController` (ID 200 wrapper). `ping`, `snapshot()` (model/version/voltage/button), `set_dxl_power`, `set_chest_led`. `BoardSnapshot::voltage_volts()` 환산.

### CLI

`forge` 5개 서브커맨드 (list-joints + ports + ping + scan + board):

```sh
forge ports                                  # USB 직렬 포트 나열
forge ping --port /dev/cu.usbserial-XXXX     # ID 200 PING (default)
forge ping --port ... --id 5                 # 모터 ID 5 PING
forge scan --port ... --range 1-20           # ID 1..20 스캔
forge board --port ...                       # CM 보드 상태 (전압 등)
forge list-joints                            # 캐논 JointID 표
```

**컨테이너에서 검증 가능한 명령:** `list-joints`, `ports` (포트 없는 빈 결과)
**Mac에서 실 검증 필요:** `ping`, `scan`, `board` (실기기 USB 연결 필수)

### 검증

| 항목 | 결과 |
|------|------|
| `cargo build --workspace` | ✅ |
| `cargo test --workspace` | ✅ **26 / 26 PASS** (Phase 4 18 + Sprint 1 신규 8) |
| `cargo clippy --workspace --all-targets -- -D warnings` | ✅ |
| `cargo fmt --check` | ✅ |
| `forge --help` | ✅ 5개 서브커맨드 표시 |
| `forge list-joints` | ✅ 16개 관절 출력 |
| `forge ports` | ✅ "(USB 직렬 포트 없음 …)" 출력 (Linux 컨테이너) |

신규 테스트 8개:
- bus: 5 (ping, read, write, scan basic, recv reject bad header)
- cm: 3 (ping ID 200 byte 검증, snapshot decoding, set_dxl_power 패킷)

## 자기검증 결과

- [x] LoopbackBus 단위 테스트로 codec ↔ bus 통합 회귀
- [x] PosixSerial은 `serialport` crate v4.7 + `nix` 의존성으로 macOS/Linux 양쪽 빌드
- [x] CLI ergonomics: `--port`, `--id`, `--baud`, `--timeout`, `--range` 통일된 인자
- [x] 안전: ping 실패 시 exit code 1
- [x] 안전: voltage < 9.5 V 시 경고 출력
- [x] 모든 PUBLIC API에 doc comment

## Mac에서 실기기 검증 (사용자 작업)

```sh
# 1. forge 빌드
cargo build --release --manifest-path app/core/Cargo.toml

# 2. 케이블 연결 후 포트 식별
./app/core/target/release/forge ports

# 3. CM 보드 핑
./app/core/target/release/forge ping --port /dev/cu.usbserial-XXXX

# 4. 모터 스캔
./app/core/target/release/forge scan --port /dev/cu.usbserial-XXXX --range 1-20

# 5. 보드 상태 (전압 포함)
./app/core/target/release/forge board --port /dev/cu.usbserial-XXXX
```

기대값:
- `ports` → `/dev/cu.usbserial-A1B2C3D4` 같은 노드
- `ping` → `PING ID 200 OK (error_byte=0x00, params=[])`
- `scan` → `응답한 ID: 1, 2, 3, 4, 5, 6, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20`
- `board` → 모델 730/740, 버전, 전압 11.x V

## Blockers

없음.

## 다음 단계

**Sprint 2 — Live Joint Control** 즉시 자율 시작:
- `forge-core/src/joint/state.rs` — `JointState` (position, speed, load, temperature, voltage)
- `forge-core/src/dynamixel/sync.rs` — SYNC_WRITE / BULK_READ 코덱
- `forge-core/src/control/loop.rs` — 8 ms tick read-write 루프
- `forge` CLI: `joint set --id 5 --position 2048` / `joint torque off --all`
- 안전: 한계각 클램프 + 한계 속도

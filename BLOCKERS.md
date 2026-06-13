# BLOCKERS

> 자율 실행 중 막힌 항목, 또는 즉시 조치해야 할 코드 이슈를 적는다.
> 우선순위가 높은 것이 위. 해결 시 ✅ 표시 + "해결" 섹션으로 이동.

---

## 🟠 활성 (2026-06) — 실기·심사·레이턴시

| # | 영역 | 이슈 | 상태 |
|---|------|------|------|
| **B-LAT1** | 레이턴시 | E-STOP/UDP 명령 패스트레인은 완비됐으나 **Mac 핸드셰이크 미사용으로 100% 미배선** | 활성 — 설계 `docs/design/cockpit-latency-hardening.md`, [조사 보고서](docs/reports/2026-06-13-latency-network-investigation.md)(9-에이전트, 2026-06-13) |
| **B-LAT2** | 네트워크 | **무선 경로 고착** — 유선 192.168.123.1이 무선보다 ~166x 빠르나 폴러가 무선에 고착, SSH 폴링 4~8Hz | 활성 — 앱 '유선' 재프로브 배너(`f1af504`)로 일부 완화 |
| **B-LAT3** | 계측 | E-STOP 물리정지 타임스탬프 계측 수단 부재 → **레이턴시 0샘플**, 외부 UDP estop이 파일럿 disarm 미동작, 무장 타임아웃 부재 | 활성 |
| **B-AS1** | App Store | 코드(P0/P1 시나리오 B) 완료, **개발자 포털 잔여**: 새 App ID·provisioning profile 재발급·App Store Connect 새 앱 레코드 + 아카이브 실기 검증·데모 영상 | 활성 — 사용자 포털 작업 |
| **B-HW1** | Switch | Switch 어플라이언스 **하드웨어 미검증**(RCM jig 미보유) — 부팅·kiosk·전원버튼·read-only rootfs 경로 미검증. 코드 레벨(bash -n·compileall)만 통과 | 활성 — 실기 게이트 |
| **B-FLD1** | 실기 필드 | WalkLab P7(32/20/L2)·킥 K3·D1/D2·H1/H2 호스트 테스트만 GREEN, **필드 게이트 미수행**. O3(FSR/IMU 밸런스) 코드 미구현 | 활성 — 입회 일정 미정 |

> 실기 측정 시 **Mac 앱 종료 필수**(시리얼 경합). 로봇·워크트리는 단일 공유 자원 — 세션당 한 번만 접근.

## 🔴 Critical — 즉시 수정 (실 motor 손상 위험 또는 광고-구현 모순)

발견: 2026-05-12 코드 감사 (`docs/reports/AUDIT_MOTION_WALK_SYNTH.md`)

| # | 위치 | 이슈 | 영향 | 액션 |
|---|------|------|------|------|
| ~~**C1**~~ | ~~`app/core/forge-core/src/synth/ops/mirror.rs`~~ | ~~off-by-one~~ | ~~mirror 깨짐~~ | ✅ **2026-05-12 해결** (인덱싱 + MIRROR_PAIRS 모드 정정, 회귀 테스트 추가). 아래 "해결" 섹션 참고. |
| ~~**C2**~~ | ~~`app/core/forge-core/src/synth/library.rs::infer_body_regions`~~ | ~~동일 off-by-one~~ | ~~Layer 합성 결합 어긋남~~ | ✅ **2026-05-12 해결** (ID 1..=20 직접 순회). `mutate.rs::JointOffset` 같은 패턴도 함께 정정. |
| ~~**C3**~~ | ~~`docs/architecture/walking-engine.md`~~ | ~~"ROBOTIS 1:1 포팅"이라 광고하나 stub~~ | ~~production-ready 오해 가능~~ | ✅ **2026-05-12 해결** (헤더 정정 + 구현 매트릭스 추가, Walk Lab UI 에 "Sim only" 배너). |

## 🟠 High — 1주 이내 (안전·정확성 영향)

| # | 위치 | 이슈 | 액션 |
|---|------|------|------|
| **H1** | `safety::self_collision` | docstring 5종 룰 / 코드 4종 (hip + knee 결합 룰 미구현) | 5번째 룰 구현 + 단위 테스트 |
| ~~**H2**~~ | ~~`synth::validator::velocity`~~ | ~~calibration 데이터 부재~~ | ✅ **2026-05-12 해결** — `tests/fixtures/velocity_calibration.json` (1100 sample) 생성, `examples/calibrate_velocity` 자동화, p99×1.1=5.21≈상수 5.2 일치 검증. |
| ~~**H3**~~ | ~~`joint::state::JointLimits`~~ | ~~"Page 12 가 V1 FAIL"~~ | ✅ **2026-05-12 해결** — off-by-one(C1) 정정 후 page 12 V1 PASS 확인. `page_12_right_kick_passes_v1_with_margins` 회귀 테스트 + 마진 53 raw (HeadTilt 4.66°) 측정값 명시. |
| ~~**H4**~~ | ~~`synth::ops::procedural::Bezier`~~ | ~~표준 cubic Bezier 아님~~ | ✅ **2026-05-12 해결** — Curve 와 module docstring 에 "**scalar 큐빅 베지어** — y(x) easing 함수, p1.0/p2.0 x 무시" 명시. 표준 cubic-bezier 호환 필요 시 별도 함수로 추가 권장. |
| ~~**H5**~~ | ~~`synth::ops::mirror::mirror_page`~~ | ~~name involution 깨짐~~ | ✅ **2026-05-12 해결** — `mirror_page` 이름 생성 로직: `_mirror` 접미사 이미 있으면 제거 (원본 복원), 없으면 추가. `mirror_name_is_involutive` 회귀 테스트. |

## 🟡 Medium — 1개월 (출처 / 근거 보강)

| # | 위치 | 이슈 |
|---|------|------|
| ~~M1~~ | ~~`walk::imu::ComplementaryFilter`~~ | ~~α=0.98 출처 부재~~ | ✅ **2026-05-12 해결** — module docstring 에 시정수 도출 (τ=Δt·α/(1−α)=392 ms) + ROBOTIS 동일값 사용 + Pieter-Jan 2013 인용. |
| ~~M2~~ | ~~`walk::ini_pose::WALK_READY_MOV_STEPS=750`~~ | ~~도출 식 미노출~~ | ✅ **2026-05-12 해결** — docstring 에 `mov_time × 1000 / control_cycle = 6.0 × 1000 / 8 = 750` 식 명시. `VIA_TIME_RATIO=2/3` 도 함께. |
| ~~M3~~ | ~~`safety::torque_ramp [0,8,16,32]`~~ | ~~안전 근거 부재~~ | ✅ **2026-05-12 해결** — `safety::torque_ramp` 모듈 docstring 에 "Provenance" 절 추가 (왜 0, 8, 16, 32 / 4 단계 / 200 ms × 4 = 800 ms 인지). 실 모터 실측은 G3 게이트 후. |
| ~~M4~~ | ~~`synth::validator::static_stability::MAX_HIP_PITCH_DIFF_RAW=1700`~~ | ~~margin 정량화 부족~~ | ✅ **2026-05-12 해결** — walkReady L−R = 1479 raw 기준 +221 raw 마진. Page 12 kick 차이 1379 raw 마진 안. single_foot_ok 와 분리 설계 명시. |
| M5 | `synth::library::OFFICIAL_CATALOG` | ROBOTIS 원본 오타 vs 정정 여부 모호 |
| M6 | `docs/motion-format/page-format.md` | `> TODO: verify` 가 page-catalog-motion4096.md 와 충돌 |

## 🟢 Low — 이슈 정리 사이클

- 단위 docstring 일관성 (raw / deg / rad 혼재)
- `POSITION_MASK` vs `MAX_POSITION` 중복 정의
- ±180° 비대칭 매핑 (0..4095 / 2048 중심)
- `synth::ops::layer` 의 slot 0 fallback 묵시적 처리

---

## 잠재 위험 항목 (선제 인지 — 환경적)

- **Mac 빌드 검증 불가**: 컨테이너에 swift/Xcode 미설치. SwiftUI 코드는 작성하되 컴파일 검증은 사용자 Mac에 위임. 보고서에 `swift build` 명령어 명시.
- **실기기 통합 테스트 불가**: USB로 실제 OP1/OP2와 통신은 Mac에서만 가능. Rust 단위 테스트는 가짜 시리얼 백엔드(loopback) 사용.
- **emanual.robotis.com WebFetch 차단**: 자동 수집은 GitHub 저장소와 ROBOTIS-OP-Series-Data PDF 위주.
- **펌웨어 업로드**: 부록 A에 따라 사용자 명시 확인 전 절대 수행 금지. Sprint 5 이전에는 토픽으로 다루지 않음.
- **GPL 코드 임베드 위험**: ROS 일부 패키지·HROS5-Framework가 GPL. `vendor/LICENSES.md`로 격리·기록만 하고 코어에 직접 임베드하지 않음.

---

## 해결 (Resolved)

### 2026-05-12 — C1 / C2 / C3 정리

**C1 + C2 (mirror.rs / library.rs / mutate.rs off-by-one)**

- `MotionStep::positions[i]` ↔ `JointId i` 규약 명시 (slot 0 미사용, 1..=20 관절, 21..=30 reserved).
- `synth/ops/mirror.rs` — `(id - 1) as usize` → `id as usize` 로 정정. `MIRROR_PAIRS` 모드도 page 12 walkready anchor 의 R+L 합계(≈4096) 재검증 결과 **모두 SwapReflect** 로 통일 (이전 "Swap only" 분류는 잘못된 인덱싱으로 인한 잘못된 페어 매칭의 부산물).
- `synth/library.rs::infer_body_regions` — `for i in 0..N { let id = i+1 }` → `for id in 1..=20 { let i = id as usize }`.
- `synth/ops/mutate.rs::JointOffset` — 같은 패턴 발견·정정.
- 회귀 테스트 추가: `mirror_of_rk_legs_approximate_lk_tightly` — page 12 → page 13 다리 mirror 의 mean abs diff < 200 raw (~4.4°). `mirror_of_rk_approximates_lk` 임계도 600 → 500 으로 강화.
- 검증: `cargo test -p forge-core` 276/276 통과.

**C3 (walking-engine.md 광고-구현 모순)**

- `docs/architecture/walking-engine.md` 상단에 **"현재 상태"** 블록 추가 — 현재 코드는 MVP sin 파 stub 임을 명시.
- "현재 구현 vs 명세 매트릭스" 표 추가 (보행 주기 ✓ / 발 궤적 △ / 골반 보상 ✗ / 팔 swing ✗ / IK ✗ / IMU balance ✗ / 모터 송출 ✗).
- Walk Lab UI (`WalkLabView`) 디테일 영역 상단에 **"Sim only — 실 IK 미구현 (BLOCKER C3)"** 정보 배너.
- 부수: Walk Lab 의 IMU/온도 시뮬 모델 추가 (`updateSimIMU` / `updateSimThermal`) — L3 (|roll/pitch|>30°) / L4 (60°C) 자동정지 게이트 실제 동작 검증 경로 확보.

### 2026-05-12 — 데이터·모터 값 적정성 점검 (Mac 빌드 전 완성도 향상)

**A: D3 + D6 — 회귀 테스트**

- `synth::validator::joint_limit::page_12_right_kick_passes_v1_with_margins` — 가장 극단 자세인 page 12 right kick 의 V1 PASS + per-joint 마진 산정 + 최소 마진 53 raw (HeadTilt 4.66°) lock-in. BLOCKER H3 의 "page 12 가 FAIL 한다"는 주장 무효 검증.
- `walk::preset::all_presets_sim_foot_within_walkparams_box` — 8개 프리셋 sim 결과의 발 위치가 `WalkParams.foot_height` 안임을 한 사이클 분량으로 검증.
- `walk::preset::full_slider_range_sim_stays_bounded` — advanced 모드 슬라이더 풀-스윙 (x ±0.05 / y ±0.03 / a ±0.3 / period 400~800) 도 sim 범위 내.

**B: D1 — fixture 4건 추가 + 디코더**

- `examples/decode_motion <page_id>` — `motion_4096.bin` byte-preserving 디코더 + Rust source 출력. page 1 init 와 byte-exact 매칭 검증.
- 신규 fixture: `page_3_no` (head shake), `page_4_hi` (waving — gui 라벨 "Thank you"), `page_10_get_up_front` (Caution recovery, knee 0x0c5e=3166), `page_15_sit_down` (deep squat, knee 0x0db9=3513).
- 회귀 테스트 5건: 디코더 byte-exact + 각 fixture 별 motion 특성 invariant.
- Catalog fixture coverage: 5/16 → **9/16**.

**C: D2 + D5 — Provenance docstring**

- `JointLimits::for_joint` — 11 관절별 ±한계 결정 근거 표 (walkReady·kick 마진 실측 기반) + ROBOTIS dxl_init.yaml 의 "Dynamixel 레벨 무제한" 사실 명시.
- `safety::torque_ramp` — `[0, 8, 16, 32]` × 200 ms × 4 단계 = 800 ms ramp 결정 근거 (각 P-gain 단계의 물리적 의미).

**D: D4 — Velocity calibration 데이터화**

- `examples/calibrate_velocity` — 16 catalog 페이지의 1,100 step transition sample 통계 산출.
- `tests/fixtures/velocity_calibration.json` — overall p50/p90/p95/p99/max + per-joint max + per-page 상세.
- 측정 결과 (p99=4.74, max=10.26 raw/ms) 가 기존 상수 `WARN_RAW_PER_MS=5.2` / `MAX_RAW_PER_MS=11.3` 와 ±0.1 이내 일치 검증 (`thresholds_match_calibration_fixture` 회귀).
- BLOCKER H2 (calibration 데이터 미공개) → 해결.

검증: `cargo test --workspace` 329 tests (forge-core 292 + forge-cli 10 + forge-mcp-synth 30 + 기타) 통과.

검증(2026-06-14 실측): `cargo test --workspace` exit 0, 382 passed / 0 failed / 2 ignored(doc-test).

### 2026-06 — 실기 브링업 결함 해소

- **F9 E-STOP 복구 결함** (`1d8c6ff`): E-STOP 복구 시 관절 enable 미복원('ACK≠서보 기록') 결함 수정 — `GamepadPilot.cpp` 재무장 분기에 SetEnableHeadOnly/SetEnableBodyWithoutHead 추가, stale cmd 가드. 실기 입회 확인(2026-06-13).
- **F6/F7 버스 선점** (`465b7d9`): 연결 시 버스 선점·하드 타임아웃·cmd 쓰기 폴백 — 무선 고착 연결 실패 완화.
- **킥 안정성** (`58efaa8`): 사커킥 스냅 72ms 과속 → steps2~4 감속(72→144ms, 체크섬 byte31 sum≡0xFF)·착지 settle ~300ms·사후 낙상 즉시 getup. 실기 배포.
- 참고: 기존 H1(self_collision 5번째 룰)은 여전히 미해결(Medium M5/M6 포함).

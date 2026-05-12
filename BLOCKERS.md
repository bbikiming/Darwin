# BLOCKERS

> 자율 실행 중 막힌 항목, 또는 즉시 조치해야 할 코드 이슈를 적는다.
> 우선순위가 높은 것이 위. 해결 시 ✅ 표시 + "해결" 섹션으로 이동.

---

## 🔴 Critical — 즉시 수정 (실 motor 손상 위험 또는 광고-구현 모순)

발견: 2026-05-12 코드 감사 (`docs/reports/AUDIT_MOTION_WALK_SYNTH.md`)

| # | 위치 | 이슈 | 영향 | 액션 |
|---|------|------|------|------|
| **C1** | `app/core/forge-core/src/synth/ops/mirror.rs` | `positions[ID-1]` off-by-one — 다른 모든 모듈은 `positions[i] = ID i` 규약 (slot 0 unused) | walkready/kick 페이지 mirror 시 R_SHOULDER_PITCH 가 INVALID flag(0x4000)로 손상 → 실 motor 송출 시 unpredictable | 인덱싱 수정 + byte-exact 회귀 테스트 (motion_4096.bin page 9 fixture) |
| **C2** | `app/core/forge-core/src/synth/library.rs::infer_body_regions` | 동일 off-by-one (`let id = (i+1)`) | UpperBody/LowerBody/Head 자동 메타데이터 한 칸 어긋남 → `Layer` 합성 시 잘못된 부위 결합 | 인덱싱 수정 + 단위 테스트 |
| **C3** | `app/core/forge-core/src/walk/engine.rs` ↔ `docs/architecture/walking-engine.md` | 코드 docstring은 "MVP, 단순 sin파 stub" 솔직히 적었으나 walking-engine.md는 "ROBOTIS 1:1 포팅"이라 광고. 실제로는 `op2_walking_module.cpp::computeLegAngle` 13× wSin + IK와 알고리즘이 완전 다름 | 사용자가 walking-engine.md 보고 production-ready로 오해 가능 | walking-engine.md를 "현재 MVP stub" 으로 정정 + 실제 IK 구현 Sprint X 명시 |

## 🟠 High — 1주 이내 (안전·정확성 영향)

| # | 위치 | 이슈 | 액션 |
|---|------|------|------|
| **H1** | `safety::self_collision` | docstring 5종 룰 / 코드 4종 (hip + knee 결합 룰 미구현) | 5번째 룰 구현 + 단위 테스트 |
| **H2** | `synth::validator::velocity` | WARN 5.2 / FAIL 11.3 raw/ms 임계는 주석에 "ROBOTIS 16 페이지 calibration" 명시, 그러나 실제 calibration **스크립트 / 데이터 파일이 리포에 없음**. HVP는 "측정 완료"라 주장하나 추적 불가 | calibration 스크립트 + raw 데이터를 `tests/fixtures/`에 commit |
| **H3** | `joint::state::JointLimits` | ROBOTIS Page 12 right kick 자체를 V1 joint_limit validator가 FAIL시킴 (integration test 가 자인) — 한계가 너무 보수적 | Page 12 통과하도록 한계 완화 (단, 검증 후) |
| **H4** | `synth::ops::procedural::Bezier` | 표준 cubic Bezier 아님 — y만 사용, x 무시 | 표준화 또는 docstring에 "scalar curve, x 무시" 명시 |
| **H5** | `synth::ops::mirror::mirror_page` | name involution 깨짐 — `mirror(mirror(p)).name ≠ p.name` | 두 번 mirror 시 원본 name 복원 로직 |

## 🟡 Medium — 1개월 (출처 / 근거 보강)

| # | 위치 | 이슈 |
|---|------|------|
| M1 | `walk::imu::ComplementaryFilter` | α=0.98 출처 / 학술 인용 없음 |
| M2 | `walk::ini_pose::WALK_READY_MOV_STEPS=750` | derived constant인데 도출 식 미노출 |
| M3 | `safety::torque_ramp [0,8,16,32]` | ROBOTIS 원본에 없는 자체 추가. 안전 근거 부재 |
| M4 | `synth::validator::static_stability::MAX_HIP_PITCH_DIFF_RAW=1700` | margin 정량화 부족 |
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

(없음 — 아직)

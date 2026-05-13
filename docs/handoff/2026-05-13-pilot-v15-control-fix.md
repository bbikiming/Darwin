# Remote Pilot v1.5 — 진단 + 안전 확장 (Sprint 17)

**날짜**: 2026-05-13
**브랜치**: `claude/pilot-v15-control-fix`
**기반 컨설팅**: Codex CLI (2회 라운드, 1+6+2 권고 모두 반영)

---

## TL;DR

> "현재 로봇을 컨트롤 못 한다" 문제의 핵심 원인은 **연결 자체보다 실패가 성공처럼 표시되는 UX**.
> `applyPoseSmoothly` 가 SafeMotion 거부 / write 실패를 silently swallow → TeleopChannel 이
> "완료" 토스트를 잘못 띄움.
>
> v1.5 는 이를 결과 반환형 (`PoseApplyResult`) 으로 surface 하고, 진단 패널 + ARM 게이트
> 강화 + 안전한 v1.5 부분집합 활성 + 메인 7 + 안전한 추가 4 페이지 (head/arm 단발) 로 마무리.

---

## 변경 파일 (10개)

| 파일 | 변경 요약 |
|------|---------|
| `ConnectionStore.swift` | `PoseApplyResult` enum (`completed` / `partialFailure` / `notConnected` / `rejected` / `cancelled` / `writeFailed` / `criticalLoad`) + 하체 12 joint set + position/speed 실패 분리 카운트 |
| `TeleopChannel.swift` | 시뮬 ARM 분리 (gate.arm 호출 안 함), 토크 retry-then-fail (하체 1개라도 실패 → ARM 차단, 상체 4개+ 도 차단), walkReady 결과 분기, `readyDegraded` stage 신규, sendMotion/sendPose 결과 surface, `DispatchSummary` 발행 |
| `PilotDiagnosticsPanel.swift` (신규) | endpoint + RTT + 마지막 통신 + success/failure count + 마지막 송출 결과 색상 분기 (success ✓ / partial ⚠ / sim ⊙ / error ✕) + lastSafetyEvent / lastRecoveryResult row |
| `PilotFeatureFlags.swift` | `PilotFeatureLevel` enum (v1.0 / v1.5), `v1_5` 를 안전 부분집합으로 재정의 (actionBarMore + bridgeNetwork only), `v1_1_future` / `v2_future` placeholder |
| `RemotePilotView.swift` | `@AppStorage("df.pilot.featureLevel")` 즉시 반영 (이전 `static let` 재시작 필요), 헤더 우상단 Menu picker, topBanner 강화 (.error → 큰 빨간 + 재연결 / .connecting → spinner / .disconnected → sim banner) |
| `MotionCatalog.swift` | slot 2/3 단발 매핑 + 라벨 "(단발)" 정직성 + duration 2600→800ms (단발 기준), slot 24/27 안전한 자세 재사용 (`surprise` / `shy`) — slot 10/11 nil 유지 (chain 필요) |
| `PoseLibrary.swift` | `nod_target` (headTilt -15), `shake_target` (headPan 20) 신규 — slot 2/3 의 단발 근사 |
| `PilotArmSlider.swift` | `.simReady` / `.readyDegraded` stage 라벨 |
| `IntentDispatcher.swift` | `runApplyNamedPose` 가 결과 받아 Claude speak 응답 분기 (✓/⚠/ℹ/✗) |
| `PilotTests.swift` | feature flag matrix 재작성 (v1.5 안전 부분집합 검증), `PilotFeatureLevel` enum 매핑 테스트 추가 |

---

## "로봇 컨트롤 안 됨" 의 진단 + 해결

### Codex 1차 진단 (가능 원인 5건)

| 코드 | 원인 | 진단 방법 | v1.5 해결 |
|------|------|---------|---------|
| A | 연결 자체 실패 (USB 미인식 / forge serve 미실행) | Pilot 진단 패널의 "미연결" status | 연결 마법사 ⌘1 + 진단 패널 노출 |
| **B** | **SafeMotion 거부 silently swallow** | 이전엔 surface 없음 | **`PoseApplyResult.rejected` + 진단 패널 row** |
| C | walkReady 실패해도 "준비 완료" 표시 | 이전엔 분기 없음 | **`gate.arm()` 호출 전 결과 분기** |
| D | "+ 더 보기" 7개 slot 이 v1TargetPoseID=nil 라 거부 | 사용자가 "v1.5 에서 활성" 메시지 보고 혼동 | **slot 2/3/24/27 매핑 추가 + 단발 마커** |
| E | D-pad 방향이 v1.0 sim only | 이전 라벨 "v2 활성 예정" 만 | (변경 없음 — BLOCKER C3 별도 작업) |
| F | bus drop 후 사용자 인지 못 함 | 이전 작은 배너 | **큰 빨간 배너 + 재연결 버튼** |

### Codex 2차 보강 (이번 PR 에 모두 포함)

1. **writeFailed 임계 강화**: 절반 이상 실패만이 아닌, **하체 1개 position write 실패도 hard fail**
2. **시뮬 ARM 분리**: `gate.arm()` 호출 안 함 → "ARM" 단어 = 실 로봇 동작 허가만
3. **토크 ON retry**: 실패 joints 만 100ms 후 1회 재시도, 그래도 실패하면 하체 1개=차단 / 상체 4개+=차단
4. **UI 텍스트 정정**: "모터 X/Y" → "위치쓰기 P개·속도쓰기 S개 (관절 총 T)" — write 명령 수 vs 모터 수 혼동 제거
5. **다른 callers (IntentDispatcher) 결과 surface**: Claude pose 명령도 분기 응답
6. **단발 라벨 정직성**: slot 2/3 라벨 "(단발)" + duration 800ms 로 낮춤
7. **readyDegraded stage**: 상체 토크 1-3개 실패 시 ARM 됐지만 별도 표시
8. **하체 메시지 정확성**: "균형 위험" → "지지 자세 불확실" (Codex 권고 반영)

---

## v1.5 feature 활성 매트릭스

| 기능 | v1.0 | v1.5 | v1.1_future | v2_future |
|------|:----:|:----:|:------:|:----:|
| actionBarMain (7 페이지) | ✅ | ✅ | ✅ | ✅ |
| actionBarMore (9 페이지 시트) | 🔒 | ✅ | ✅ | ✅ |
| bridgeNetwork (forge serve 데몬) | 🔒 | ✅ | ✅ | ✅ |
| imuTelemetry | 🔒 | 🔒 | ✅ | ✅ |
| autoRecovery (낙상) | 🔒 | 🔒 | ✅ | ✅ |
| headTracking / ballFollow | 🔒 | 🔒 | ✅ | ✅ |
| camera (mjpg-streamer) | 🔒 | 🔒 | 🔒 | ✅ |
| hsvTuning | 🔒 | 🔒 | 🔒 | ✅ |
| dpadRealMotor (실 IK) | 🔒 | 🔒 | 🔒 | ✅ |
| pageChain | 🔒 | 🔒 | 🔒 | ✅ |
| mp3Playback | 🔒 | 🔒 | 🔒 | ✅ |

**Codex 권고 반영**: 이전 v1.5 가 IMU/카메라까지 포함했으나, 이는 "작동하는 것처럼 보이는" 위험.
v1.5 에서 새로 활성되는 건 `actionBarMore` (안전 단발 자세만) + `bridgeNetwork` (네트워크 endpoint 옵션).

---

## "+ 더 보기" 9 페이지 매핑 현황

| Slot | Raw | Korean | v1.5 매핑 | 비고 |
|---:|---|---|---|---|
| 1  | init | 기본 자세 | idle | 메인 7 |
| 2  | ok | **고개 숙이기 (단발)** | nod_target (headTilt -15) | **신규** — 원본 chain 은 v1.6 |
| 3  | no | **고개 돌리기 (단발)** | shake_target (headPan 20) | **신규** — 원본 chain 은 v1.6 |
| 4  | hi | 감사 인사 | bow_60 | 메인 7 |
| 9  | walkready | 보행 자세 | walk_ready | 메인 7 |
| 10 | f up | 앞 일어서기 | **nil** | 다단 chain 필요 — fall risk |
| 11 | b up | 뒤 일어서기 | **nil** | 다단 chain 필요 — fall risk |
| 12 | rk | 오른발 차기 | kick_forward_right | 메인 7 (HighRisk) |
| 13 | lk | 왼발 차기 | **nil** | 좌우 mirror 자세 추가 별도 PR |
| 15 | sit down | 앉기 | sit_chair | 메인 7 |
| 16 | stand up | 일어서기 | idle | 더보기 (idle 재사용) |
| 23 | d1 | 출발! | hands_up | 메인 7 |
| 24 | d2 | 감탄 | surprise | **재사용** |
| 27 | d3 | 실수 | shy | **재사용** |
| 38 | d2 bye | 손 흔들기 | wave_right | 더보기 (기존) |
| 54 | int | 박수 요청 | clap_ready | 더보기 (기존) |

**현재 활성**: 메인 7 + 더보기 7 = **14/16**.
**여전히 nil**: slot 10/11 (get up 류, chain 필요 — fall risk), slot 13 (왼발 차기, mirror 자세 부재).

---

## 빌드 + 테스트

```bash
make mac      # FFI .a + 헤더 재생성
cd app/ui/DarwinForge && swift build   # ✓ Build complete
cd app/ui/DarwinForge && swift test    # ✓ 159/159 passed (1 추가)
```

---

## 사용자 검증 시나리오 (정비 스탠드 권장)

1. **연결 진단**
   - 앱 실행 → ⌘1 연결 마법사 → USB / 네트워크 시도
   - 진단 패널 노출 확인 — endpoint, RTT, voltage 라이브 갱신

2. **시뮬 모드 ARM 검증**
   - 로봇 연결 없이 ⌘8 Pilot 진입
   - ARM 슬라이더 → "시뮬 모드 — ARM 불필요, 미리보기" 토스트
   - 시뮬 ARM stage = `.simReady` — gate.armed=false 유지
   - Action Bar 버튼 → "시뮬 미리보기" 라벨 + 3D 자세 변화

3. **실 로봇 ARM 검증**
   - 정비 스탠드 거치 + 배터리 11V+ 확인
   - ⌘1 USB 연결 → Pilot 진입
   - ARM 슬라이더 → enablingPower → rampingTorque → reachingWalkready → ready
   - 진단 패널의 "마지막 송출" row 가 "보행 자세 (ARM)" + 결과 표시

4. **하체 토크 실패 시뮬**
   - 모터 ID 11 또는 13 (hip/knee) USB 케이블 살짝 흔들기
   - ARM → "ARM 차단 — 하체 토크 1개 실패 (R_HIP_PITCH)" 표시
   - gate.armed=false 유지 — Action Bar 비활성

5. **+ 더 보기 시트**
   - v1.5 picker 선택 → "+ 더 보기 (9 페이지)" 버튼 클릭
   - 시트 열림 → 7개 활성 (고개 숙이기/돌리기 단발 / 감탄 / 실수 / wave / clap / stand-up) + 2개 비활성 (get-up 류)

6. **연결 끊김 시나리오**
   - 연결된 상태에서 USB 케이블 분리
   - 큰 빨간 배너 "연결 오류 — 로봇과의 연결이 끊겼어요" + 재연결 버튼
   - 재연결 클릭 → 연결 시도

---

## 향후 작업 (v1.6+)

- **motion_play 라이브러리 추출** — forge-cli/motion_play.rs → forge-core::control + FFI
  - 활성화 가능: slot 10/11 get-up chain, slot 13 mirror, pageChain
- **IMU read** — CmController::read_imu() + FFI → imuTelemetry + autoRecovery
- **카메라** — robot-side mjpg-streamer 셋업 가이드 + 라이브 view
- **D-pad 실 IK** — ROBOTIS-OP2 op2_walking_module Rust 포팅 (BLOCKER C3)
- **bridge wizard CTA** — 첫 연결 실패 시 "forge serve 실행 확인 / 포트 5530 확인" 안내

---

## Codex 2회 라운드 권고 모두 반영

### 1차 (root cause 진단)
- ✅ `PoseApplyResult` 결과 반환형 도입 (silently swallow 차단)
- ✅ ARM 게이트를 walkReady `.completed` 에 의존
- ✅ 진단 패널 — endpoint / RTT / last command
- ✅ feature picker `@AppStorage` 즉시 반영
- ✅ bus drop 큰 빨간 배너
- ✅ v1.5 안전 부분집합 (IMU/camera 미포함)

### 2차 (정책 강화)
- ✅ writeFailed 임계 강화 (하체 1개 = hard fail)
- ✅ 시뮬 ARM 에서 gate.arm() 분리
- ✅ 토크 ON retry-then-fail
- ✅ UI 텍스트 "모터" → "위치쓰기/속도쓰기" 정확성
- ✅ IntentDispatcher 결과 surface
- ✅ 단발 라벨 정직성 + duration 낮춤

### 추가 보강 (2차 정책 판단 반영)
- ✅ `readyDegraded` stage — 상체 토크 일부 실패 후 ARM 시각 구분
- ✅ duration 2600ms → 800ms (단발 자세 적정)

---

## 안전 노트

본 PR 은 **사용자 보고된 "로봇 컨트롤 안 됨" 문제의 진단/UX 결함** 을 일관성 있게 해결.
**아직 검증 안 된 영역**:
- 실 로봇 HIL 시나리오 (사용자 Mac + DARwIn-OP 필요)
- 상체 토크 부분 실패 ARM 진행 후 실제 동작 영향 (사용자 검증 필요)
- 단발 자세의 사용자 인지 (끄덕임이 아닌 "고개 숙이기" 로 받아들이는지)

머지 전 정비 스탠드 + 배터리 충전 + 실 시나리오 1-3 (위 검증 시나리오) 수행 권장.

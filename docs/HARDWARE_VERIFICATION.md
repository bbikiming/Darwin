# 실기기 검증 체크리스트 — DARwIn-OP / OP2

> Mac + 실 OP1/OP2 로봇으로 진행하는 단계별 검증 절차.
> 각 단계는 *통과*해야 다음으로 진행. 실패 시 "복구" 컬럼 따라 원인 격리.
>
> **시작 전 필수**: [`harness/shared/safety.md`](../harness/shared/safety.md) "매번" 체크리스트 6개 완료.

## 0. 사전 준비 (앱 빌드)

```sh
git pull
make doctor                    # 도구 점검 (Rust + Swift + Xcode CLT)
make app                       # cargo build + swift build
bash scripts/smoke-test.sh     # 하드웨어 무관 스모크 5단계
```

✅ smoke-test 5/5 통과한 상태에서 §1 진입.

## 1. 호스트(Mac) 측 USB 환경 점검 (로봇 OFF)

| 단계 | 명령 / 확인 | 기대 | 실패 시 |
|------|------------|------|---------|
| 1.1 | `bash scripts/check-mac-drivers.sh` | FTDI 또는 Apple In-Kernel 드라이버 인식 | 시스템 설정 → 개인정보 보호 → 시스템 확장 허용 |
| 1.2 | `ls /dev/cu.*` | (목록 — 빈 결과여도 정상) | — |
| 1.3 | `./app/core/target/release/forge ports` | (USB 직렬 포트 없음) | — |

## 2. 로봇 1세대 (OP1 / CM-730) — 첫 연결

> 시작 전: 로봇을 정비 스탠드(cradle)에 거치, e-stop 토글 OFF, LiPo cell당 ≥3.7 V 확인.

| 단계 | 명령 / 동작 | 기대 | 실패 시 |
|------|------------|------|---------|
| 2.1 | LiPo 연결 → e-stop ON → CM 전원 LED 켜짐 | 빨간색 또는 녹색 LED | LiPo 점검 / SMPS 대체 시도 |
| 2.2 | Mac에 USB Mini-B 연결 → `forge ports` | `/dev/cu.usbserial-XXXXXX` 1개 출현 | `harness/shared/mac-driver-setup.md` §트러블슈팅 |
| 2.3 | `forge connect --port /dev/cu.usbserial-XXXX` | CM 모델 = 730, **응답 ID 20/20**, 매핑 = Official | 누락 ID 보고 시 §2.5a/b 참고 |
| 2.4 | `forge board --port ...` | `Model: 730, Battery: ~11.x V` | board snapshot 실패 시 펌웨어 진단 (별도) |
| 2.5 | `forge scan --port ... --range 1-20 --timeout 50` | 응답 ID 20개 (1-6, 7-18, 19-20) | 빠진 ID는 daisy chain 끊김 — `harness/op1/leg-l-bus.yaml` 결선 점검 |
| 2.5a | 만약 7..=10이 무응답 + 11..=18은 응답 | Legacy OP1 매핑 — `forge connect` 가 자동 알림. 발목 ID 마법사 필요 |
| 2.5b | 만약 15..=18(발목)이 무응답 | **워크/직립 위험** — 펌웨어/케이블 점검 후 진행 |
| 2.6 | `forge joint state --port ... --id 19` | 8필드 출력 (HEAD_PAN) | — |
| 2.7 | `forge walk-ready --port ... --dry-run` | 20개 raw 위치 인쇄 (r_hip_pitch=1308, r_knee=3527 등) | 매핑 잘못이면 raw 값 다름 |

✅ 2.1~2.7 모두 통과 → §3 진입.

## 3. SwiftUI 앱 — Board / Joint Control (OP1)

```sh
make run    # 앱 실행
```

| 단계 | UI 액션 | 기대 |
|------|---------|------|
| 3.1 | Connection 패널 → Port Picker에서 OP1 포트 선택 → Connect | "Connected" 녹색 배지, "CM-730 (1st gen / OP)" 라벨, 배터리 V |
| 3.2 | Board Status 탭 | 모델/펌웨어/전압 1 Hz 폴링 갱신, 전압 헬스 배지 |
| 3.3 | Joint Control 탭 → HEAD_PAN 선택 → "Refresh" | 우측 상태 그리드에 Goal/Present/Speed/Load/Voltage/Temperature 표시 |
| 3.4 | HEAD_PAN "Torque ON" → 슬라이더 1900으로 천천히 → 1900에서 손 뗌 | 머리가 오른쪽으로 회전, 슬라이더 값과 Present Position 일치 |
| 3.5 | 슬라이더 2200 → 손 뗌 | 머리 좌측 회전 |
| 3.6 | "Torque OFF" → 머리 손으로 살짝 흔들기 | 자유 회전, Present Position 변화 |
| 3.7 | ⌘⇧. 단축키 | 모든 관절 토크 OFF (이미 OFF였어도 무해) |

✅ 3.1~3.7 통과 → §4 진입 (또는 OP2로 §2 반복).

## 4. walkReady 자세 + 모션 카탈로그 (OP1)

```sh
# 안전한 토크 ramp + 자세 보간으로 공식 walkReady 자세 적용.
forge walk-ready --port /dev/cu.usbserial-XXXX
```

| 단계 | 명령 / UI 액션 | 기대 |
|------|--------------|------|
| 4.0 | `forge motion catalog` | 16개 모션 표 (11 Safe + 2 Caution + 3 HighRisk), motion_4096.bin 매칭 ✓ |
| 4.1 | `forge walk-ready --port ... --dry-run` | RHipPitch raw≈1308, RKnee raw≈3527, RAnklePitch raw≈2844 — `ini_pose.yaml` 1:1 일치 |
| 4.2 | `forge walk-ready --port ...` (실 적용) | P_GAIN ramp 4단계 (0→8→16→32), 자세 부드럽게 이동, "둠칫" 없음, 60초 후 모터 온도 < 50 °C |
| 4.3 | Motion Library → "Import .mtn" → `app/core/forge-core/tests/fixtures/sample-2page.mtn` | 좌측 리스트에 "sample-2page.mtn" 추가, safety 배지 |
| 4.4 | 디테일에서 JSON ↔ .mtn 토글 | 두 보기 모두 31-슬롯 step 5개 + safety_class 필드 표시 |
| 4.5 | HighRisk 모션 (Hand Standing 등) 실행 시도 | "HighRisk — confirm_risk=true 필요" 다이얼로그 |

> 실제 walk 재생(이동/회전)은 Phase C IK + IMU loop 완성 후. 현재는 walkReady 자세까지만.

## 5. 로봇 2세대 (OP2 / CM-740) — 동일 절차 반복

§1, §2, §3을 OP2로 반복:
- 2.4 기대값: "Model: 740"
- 그 외 모두 동일

✅ OP1/OP2 모두 §3.7까지 통과하면 **연결 + Joint Control + Motion Library는 production-ready**.

## 6. 워크 시뮬레이션 (실 모터 명령 X)

```sh
# 앱의 Walk Sim 탭
```

| 단계 | UI 액션 | 기대 |
|------|---------|------|
| 6.1 | Walk Sim → x=0.04 → Enabled ON | 매 50 ms tick마다 Phase Phase1/2/3 사이클 |
| 6.2 | trace 테이블 | foot z의 최대값이 약 0.04 m (foot_height 파라미터) |
| 6.3 | x=0, y=0.02, a=0 | 좌우 발 z 위상 차이 |

## 7. Strategy FSM 시뮬레이션

```sh
# 앱의 Strategy FSM 탭
```

| 단계 | UI 액션 | 기대 |
|------|---------|------|
| 7.1 | Idle → "Step" | LookingForBall 진입 |
| 7.2 | ball pixel_count=200 → Step | ApproachingBall |
| 7.3 | ball=2000 → Step | Kicking |
| 7.4 | Step | Cooldown |
| 7.5 | since_kick_ms=2000 → Step | LookingForBall (cooldown 종료) |
| 7.6 | "Auto run 6 steps" | 6개 trace stripe 모두 표시 |

## 8. 종료 절차

| 단계 | 액션 |
|------|------|
| 8.1 | 모든 관절 토크 OFF (⌘⇧.) |
| 8.2 | App Disconnect |
| 8.3 | e-stop 토글 OFF |
| 8.4 | LiPo 분리 (스파크 방지 — 토글 OFF 후 5초 대기) |
| 8.5 | 트레이스/스크린샷 docs/reports/SPRINT_2_HW_VERIFY.md (선택)에 기록 |

## 보고

검증 완료 후 다음 정보 캡처:
- OP1, OP2 각각의 모델 번호 / 펌웨어 버전 / 배터리 전압
- 응답한 모터 ID 16개 (예상값과 비교)
- HEAD_PAN 슬라이더 → 회전 응답 영상 또는 사진
- 발견한 이슈 (BLOCKER 후보 → BLOCKERS.md 등재)

---

## 빠른 디버그 명령 모음

```sh
# 포트 못 찾을 때
bash scripts/check-mac-drivers.sh
log stream --predicate 'sender == "AppleUSBHost"' --info | head -50

# 통신 디버그
RUST_LOG=trace forge ping --port /dev/cu.usbserial-XXXX --id 200

# 한 모터 단독 진단
forge joint state --port ... --id 5
forge joint torque --port ... --target 5 --enable on
forge joint set --port ... --id 5 2048
forge joint torque --port ... --target 5 --enable off

# 모든 토크 즉시 OFF (CLI에서)
forge joint estop --port ...

# 배터리 모니터 (1초 간격, 5회)
for i in {1..5}; do forge board --port /dev/cu.usbserial-XXXX | grep Voltage; sleep 1; done
```

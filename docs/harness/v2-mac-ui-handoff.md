# Mac UI ↔ 하네스 엔지니어링 핸드오프 (v2)

> **Mac에서 DarwinForge.app을 구현·검증할 때 바로 참조할 통합 문서.**
> 하네스(하드웨어 인터페이스) 자료가 신규 모션 / 연결 / 안전 흐름과 1:1
> 정렬되었는지 점검하고, UI에 직접 매핑되는 형태로 정리.
>
> 작성 근거: 2026-05-12 코드 감사 (`docs/reports/AUDIT_MOTION_WALK_SYNTH.md`)
> + Sprint 9-13 신규 작업 (forge connect / walk-ready / motion play /
> RootView triggerQuickConnect).

---

## TL;DR — 갭 5개

| 갭 | 기존 하네스 자료 (2026-05-09 작성) | 신규 사용자 작업 (Sprint 9-13) |
|----|------------------------------------|--------------------------------|
| **G1** 통신 경로 | USB Mini-B + U2D2 두 가지만 | **이더넷 TCP 192.168.123.1:5530** 추가 — UI의 1차 CTA |
| **G2** BOM | USB Mini-B 케이블만 | + **USB-C → Ethernet 어댑터 + CAT 5e/6 패치 케이블** |
| **G3** 안전 게이트 | LiPo cell / e-stop 토글만 | + **P-gain ramp 0→8→16→32** + 모터 60°C 임계 + HighRisk `confirm_risk=true` 다이얼로그 |
| **G4** 진단 스크립트 | `forge ping / scan` 만 | + `forge connect / walk-ready / motion catalog / motion play` |
| **G5** UI ↔ 하네스 매핑 | 부재 | **toolbar 4 status pill** (Connection / Battery / Temp / Torque) 각각이 하네스 어느 상태를 보여주나? |

본 문서가 5 갭을 모두 채운다.

---

## 1. 통신 경로 3가지 — UI에 표시할 connection mode

### 1.A USB Mini-B 직결 (기본)
```
Mac USB-A/USB-C ── USB Mini-B (2 m, double-shielded) ── CM-730/CM-740
                                                       │ FTDI FT232RL
                                                       └ STM32 USART1
```
- 1 Mbps, 부팅 시퀀스 표준
- UI status pill 매핑: **Connection** = `cu.usbserial-XXXX`
- 진단: `forge ports` → `forge connect --port /dev/cu.usbserial-XXXX`

### 1.B U2D2 dongle (TTL 직접, 진단용)
```
Mac USB-C ── U2D2 ── 3-pin TTL ── Dynamixel daisy chain (CM 우회)
```
- CM 펌웨어 손상 / 단일 모터 격리 시
- UI 토글: "고급 → U2D2 모드" (현재 미구현 — UI 추가 후보)

### 1.C 이더넷 TCP (★ 신규 1차 CTA)
```
Mac USB-C ── USB-C → Ethernet 어댑터 ── CAT 5e/6 패치 케이블 ──┐
                                                                 │
                                          192.168.123.X 서브넷    │
                                                                 │
                                        DARwIn-OP onboard PC ────┘
                                          (Ethernet, 192.168.123.1)
                                            └ forge server 데몬
                                              (TCP 5530)
```
- 사용 시점: **로봇이 cradle에서 멀리 떨어진 시연 / 클래스룸**
- 장점: 케이블 텐션 없음, 무선 변환 가능 (라우터 경유)
- 단점: 로봇 onboard PC에 `forge server` 데몬 설치 필요 (별도 가이드 — 미작성)
- UI status pill 매핑: **Connection** = `192.168.123.1:5530`
- 진단: `forge connect --tcp 192.168.123.1:5530`
- **CTA 위치**: `RootView.swift::quickConnectCTA` — 우측 상단 ⚡ 버튼

### 우선순위 (사용자 시나리오별)

| 시나리오 | 권장 경로 | 이유 |
|----------|-----------|------|
| 첫 연결 / 디버깅 | **1.A USB** | 가장 안정, 모터 직접 신호 확인 |
| 데모 / 시연 | **1.C Ethernet** | 케이블 텐션 0, 무선 라우터 경유 가능 |
| CM 펌웨어 손상 진단 | **1.B U2D2** | CM 우회 |

---

## 2. BOM 갱신 — 이더넷 경로 추가 부품

> 기존 `harness/op1/BOM.md` + `harness/op2/BOM.md` 에 추가할 항목.

| # | 부품 | Mfg P/N (예) | 단가 (USD) | 비고 |
|---|------|------|------------|------|
| E1 | **USB-C → Gigabit Ethernet 어댑터** | Anker A8312 또는 Apple MJ1M2AM/A | 18 | Apple Silicon Mac은 USB-C → Ethernet 자체, Intel은 Thunderbolt 또는 USB-A 변환 |
| E2 | **CAT 5e 패치 케이블, 2 m, 차폐** | UGREEN NW122 | 6 | 5e 충분 (1 Gbps 미만 트래픽) |
| E3 | **5포트 unmanaged 스위치** (선택) | TP-Link TL-SG105 | 18 | 다중 로봇 동시 연결 시 |
| E4 | **무선 라우터** (선택, 시연용) | TP-Link Archer C6 | 35 | 192.168.123.X 서브넷 설정 |

총 추가 비용: 최소 24 USD (E1+E2만)

---

## 3. 안전 게이트 — UI에 표시할 단계

### 3.1 walk-ready P-gain Ramp (★ 신규)

`forge walk-ready` 가 실행하는 4단계 ramp:

| 단계 | P-gain | 시간 | UI 표시 (제안) |
|------|--------|------|----------------|
| 1 | 0 (free) | 0 ms — 모터 자유 회전 가능 | "준비 중…" (회색 progress) |
| 2 | 8 (low) | ~750 ms — 부드러운 시작 | "25%" (노랑) |
| 3 | 16 (mid) | ~1500 ms — 점진적 강화 | "50%" (주황) |
| 4 | 32 (full) | ~2250 ms — 완전 강성 | "100%" (녹색) |

> ⚠️ **C3 (BLOCKER)**: 코드 / 문서에 `[0, 8, 16, 32]` ramp가 있으나 **ROBOTIS 원본에는 없음** (`safety::torque_ramp` 자체 추가). 출처 / 안전 근거 부족 — 사용자 검증 필요.

**Mac UI 제안**: walk-ready 명령 실행 시 우측 상단에 progress card:
```swift
struct WalkReadyProgressCard: View {
    @ObservedObject var ramp: TorqueRampState
    var body: some View {
        VStack(alignment: .leading) {
            Text("walkReady 자세 적용 중").font(DFFont.bodyEmph)
            ProgressView(value: ramp.fraction)
            Text("P-gain \(ramp.currentGain)/32").font(DFFont.caption)
        }
    }
}
```

### 3.2 모터 온도 60°C 임계 (★ 신규)

walk-ready 60초 후 검증 — UI status pill **Temp** 가 빨강 전환 시 즉시 e-stop.

| 온도 | UI 색상 | 액션 |
|------|---------|------|
| < 40°C | 녹색 | OK |
| 40~55°C | 노랑 | 휴식 권고 (다음 명령 지연) |
| 55~60°C | 주황 | **5분 휴식 후 재시도** 권고 메시지 |
| ≥ 60°C | 빨강 | **자동 e-stop** + LiPo 분리 권고 다이얼로그 |

### 3.3 HighRisk 모션 `confirm_risk=true` (★ 신규)

`forge motion play --slot N` 에서 N이 `SafetyClass::HighRisk` 카탈로그에 속하면 (예: Hand Standing) UI는:

```
┌────────────────────────────────────────────┐
│ ⚠️ 위험한 모션 — Hand Standing               │
│                                            │
│ 이 모션은 자기충돌 / 낙상 가능성이 있어요.    │
│ 다음 조건이 모두 만족되어야 실행돼요:        │
│                                            │
│ [✓] 정비 스탠드 거치됨                       │
│ [✓] 주변 50cm 빈 공간                       │
│ [ ] confirm_risk 체크박스 (사용자 명시)      │
│                                            │
│   [취소]                  [위험 감수하고 실행] │
└────────────────────────────────────────────┘
```

전송 패킷: `forge motion play --slot N --confirm-risk`

### 3.4 매번 체크리스트 (기존 + 신규 통합)

```
□ 정비 스탠드 거치
□ e-stop 토글 ON-OFF 확인
□ LiPo cell ≥ 3.7 V (또는 SMPS 12V 5A)
□ 모터 케이스 < 40°C
□ 데이지 체인 케이블 결속
□ Mac /dev/cu.usbserial-* 또는 ping 192.168.123.1
□ ⭐ forge walk-ready --dry-run 통과 (raw 위치 ini_pose.yaml 일치)
□ ⭐ forge motion catalog 16 페이지 보임
```

---

## 4. 진단 스크립트 갱신 — `probe.sh` v2

기존 4단계 → **6단계 + 통신 경로 분기**:

```
[1/6] /dev/cu.* 후보
[2/6] (옵션) 192.168.123.1 ping
[3/6] forge connect — USB 또는 TCP
[4/6] forge board — 모델 + 전압 검증
[5/6] forge scan — 16 모터 ID 응답
[6/6] forge walk-ready --dry-run — raw 위치 검증
```

신규 출력 예:
```
✓ Port detected: /dev/cu.usbserial-A1B2C3D4
✓ TCP 192.168.123.1:5530 reachable (or skipped)
✓ Connected. Model = CM-730, Battery = 11.7 V, Mapping = Official
✓ Scan: 20/20 motors responded (IDs 1-6, 7-18, 19-20)
✓ walk-ready dry-run: r_hip_pitch=1308 r_knee=3527 r_ankle_pitch=2844 (matches ini_pose.yaml)
```

새 probe.sh는 본 commit에 포함.

---

## 5. UI Status Pill ↔ 하네스 매핑

`RootView.swift::toolbarContent` 의 4 status pill — 각각이 하네스의 무엇을 표시하나?

### 5.1 Connection pill
```swift
private var connectionToolbarPill: some View {
    // store.status:
    //   .disconnected           → 회색  "연결 끊김"
    //   .connecting(endpoint)   → 노랑  "연결 중… (endpoint)"
    //   .connected(snap)        → 녹색  "CM-7X0 / endpoint"
    //   .error(msg)             → 빨강  msg
}
```

**하네스 출처**:
- USB 경로: `cu.usbserial-*` (`harness/shared/mac-driver-setup.md`)
- TCP 경로: `192.168.123.1:5530` (본 문서 §1.C)

### 5.2 Battery pill
```swift
// fc_bus_board_snapshot()::voltage_raw / 10 = V
//   ≥ 11.1 V → 녹색
//   9.5~11.1 → 노랑 (충전 권고)
//   < 9.5 V  → 빨강 (즉시 종료 권고)
```

**하네스 출처**: LiPo cell 3.7 V × 3 = 11.1 V 기준 (`harness/shared/safety.md` §매번).

### 5.3 Temp pill (★ 보강)
- 풀링 주기: 5초 (모든 16 모터 BULK_READ 후 max)
- 색상 임계: §3.2 참조
- **신규 액션**: 60°C 도달 시 자동 e-stop trigger (`store.emergencyStop()`)

### 5.4 Torque pill
- 16 모터 중 토크 ON 개수
- 0/16: 회색 "전원만"
- 1~15: 노랑 "부분 ON"
- 16/16: 녹색 "전원 + 토크"
- ⌘⇧. e-stop: 16 → 0 즉시 전환

---

## 6. Mac UI 구현 우선순위 (P0~P2)

| Tier | 작업 | 출처 |
|------|------|------|
| **P0** | **WalkReadyProgressCard** (P-gain ramp UI) | §3.1 |
| **P0** | **HighRisk confirm 다이얼로그** (`MotionLibraryView` 재생 버튼) | §3.3 |
| **P0** | **Temp pill 자동 e-stop trigger** (60°C 임계) | §3.2 |
| **P1** | **Ethernet 경로 마법사** (192.168.123.1 ping → 안내) | §1.C |
| **P1** | **probe.sh v2** Connection wizard에서 호출 | §4 |
| **P2** | **U2D2 고급 모드** 토글 (현재 미구현) | §1.B |
| **P2** | **다중 로봇** (E3 스위치 + 다중 IP) | §2 |

---

## 7. 검증 단계 (Mac에서 실행)

```sh
# 1. 갱신된 하네스 자료 끌어오기
git pull

# 2. probe.sh v2 실행
bash scripts/harness/probe.sh /dev/cu.usbserial-XXXX
# 또는
bash scripts/harness/probe.sh --tcp 192.168.123.1:5530

# 3. 모든 6단계 통과 → make run
make run

# 4. UI에서 verify:
#    - Connection pill: 녹색 + endpoint 표시
#    - Battery pill: 녹색 + 11.x V
#    - Temp pill: 녹색 + max 온도
#    - Torque pill: 녹색 (16/16)
#    - walkReady CTA → progress card 4단계
#    - HighRisk 모션 클릭 → confirm 다이얼로그
```

---

## 출처

- `docs/HARDWARE_VERIFICATION.md` (검증 절차)
- `docs/HARDWARE_VERIFICATION_PROTOCOL.md` (3-gate G1/G2/G3)
- `docs/reports/AUDIT_MOTION_WALK_SYNTH.md` (C3 — torque_ramp 출처 부재)
- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift::toolbarContent`
- `app/core/forge-cli/src/main.rs::handle_connect / handle_walk_ready`
- `harness/shared/safety.md`, `cable-specs.md`, `mac-driver-setup.md`
- `BLOCKERS.md` — C1~C3, H1~H5

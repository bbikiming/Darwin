# Hardware Verification Protocol — Motion Synthesis

> **목적**: 합성 모션 페이지를 실 ROBOTIS-OP1/OP2 robot 에 안전하게 적용하기 위한
> **3 단계 검증 프로토콜**.
>
> **사용자**: 운영자 (Mac + USB + DARwIn-OP robot).
> **자동화 범위**: Mac 측 forge CLI 와 MCP 서버까지. 실 robot 송출 결정은 사용자.
> **버전**: v1 (2026-05-12), Sprint 12-D 산출.

## TL;DR

합성 모션을 실 robot 에 적용하려면 **3 게이트** 를 순서대로 통과해야 합니다:

1. **G1 — Static validation** (자동) — 4-stage validator 통과
2. **G2 — Dry-run** (반자동, **모터 토크 OFF**) — 페이지 데이터를 motor 에 전송하되 토크 X
3. **G3 — Live execution** (수동, **사용자 supervised**) — 토크 ON 후 한 페이지씩 재생

각 게이트 사이에 **사용자 명시 승인 단계** 가 있어야 합니다. 게이트 건너뛰기 금지.

---

## G1 — Static Validation (자동, 사용자 입력 0)

### 절차

```bash
forge synth validate path/to/page.json [--single-foot-ok]
```

또는 MCP 도구 `mcp__forge-motion-synth__validate`.

### 통과 조건

- **JointLimit (V1)** — 모든 관절 raw 값이 robot 한계 내 → PASS
- **Velocity (V2)** — 모든 step 간 변화율 < `MAX_RAW_PER_MS (11.3)` → PASS 또는 WARN (peak burst)
- **SelfCollision (V3)** — 5 종 룰 위반 없음 → PASS
- **StaticStability (V4)** — CoM proxy 양발/단발 일관성 → PASS

### 결과 처리

| Overall 결과 | 조치 |
|--------------|------|
| **PASS** | G2 로 진행 가능 |
| **WARN** (V2 burst) | 사용자에게 WARN 메시지 보여주고 진행 동의 확인. kick 같은 정상 동작 |
| **FAIL** | **G2 진행 금지.** 페이지 수정 후 재검증. `forge synth mutate ... --time-scale 1.5` 같은 회복 시도 |

### 예시

```
$ forge synth validate /tmp/kick_routine.json --single-foot-ok
# Page 200 'kick_routine'
  ✓ JointLimit       PASS
  ! Velocity         WARN  4 warn-violations: joint slot 13 8.79 raw/ms > 5.20 warn
  ✓ SelfCollision    PASS
  ✓ StaticStability  PASS
# Page 201 'kick_routine_p1'
  ✓ all PASS
✓ Overall: PASS (commit allowed)
```

---

## G2 — Dry-Run (반자동, 토크 OFF)

### 사전 준비

- Mac 과 robot 을 **USB** 또는 **TCP** 로 연결 (`forge serve` 통해 OP2 의 onboard PC 와 bridge).
- Robot 을 **테이블 / 매트 위, 안전한 자세** (앉음 또는 walkready) 로 위치.
- Robot 의 **물리적 토크 스위치 OFF** (모터가 자유롭게 회전 가능 상태) — 확인 방법:
  관절을 손으로 살짝 돌렸을 때 저항 없음.

### 실 robot 연결 확인

```bash
forge ports                              # USB 직렬 포트 목록
forge connect --port /dev/cu.usbserial-XXX  # 자동 진단 (CM-730/740 + 20 모터)
forge board --port /dev/cu.usbserial-XXX    # 보드 상태 (배터리, 온도)
forge list-joints                            # 매핑 표 출력
```

확인 항목:
- CM 보드 모델 번호 (730 vs 740)
- 모터 ID 1..=20 응답 (누락 X)
- 배터리 ≥ 11V
- 모터 온도 ≤ 50°C

### Dry-Run 절차

1. **합성 페이지 commit (사본만)** —
   ```bash
   # 절대 실 robot 의 motion_4096.bin 직접 수정 X — 사본 사용
   cp robot:/path/to/motion_4096.bin /tmp/sandbox.bin
   FORGE_MOTION_BIN=/tmp/sandbox.bin forge synth commit page.json --slot 100
   ```

2. **토크 비활성 확인** —
   ```bash
   forge joint torque --port /dev/... --all --off
   ```

3. **합성 페이지 송출 (실험적)** —
   현재 시점 (2026-05) 본 protocol 의 step 3 은 **미구현**. `forge motion play`
   같은 신규 명령이 Sprint 13 후속에서 추가될 예정. 그때까지 G2 는 데이터
   검증까지만 (실제 motor 명령 X).

4. **모니터** —
   - `forge joint state --port ... --id <n>` 로 모터 값 폴링
   - CM 보드 LED / 부저 패턴 확인

### G2 → G3 게이트

다음 모두 충족해야 G3 진행:
- 모터 ID 모두 응답 (PING 정상)
- 배터리 ≥ 11V
- 온도 ≤ 50°C
- 사용자 명시 동의 ("실행 OK")

---

## G3 — Live Execution (수동, 사용자 supervised)

### 안전 사전 점검 (사용자 책임)

- [ ] Robot 주변 **0.5m** 반경 장애물 제거
- [ ] **매트** 또는 부드러운 표면 (낙상 보호)
- [ ] **e-stop** 키 (`⌘⇧.` Studio app 또는 물리 버튼) 즉시 사용 가능 위치
- [ ] **카메라 녹화** (사고 시 분석용)
- [ ] Robot **fan / cooling** 동작 확인
- [ ] **사용자 손**이 robot 의 swing 범위 밖

### Live 절차

1. **walkReady 자세로 이동** —
   ```bash
   forge walk-ready --port /dev/... --interp-steps 60 --step-period-ms 8
   ```
   토크 ramp (P_GAIN 0→8→16→32, 4 단계) 적용. "둠칫" 현상 방지.

2. **합성 페이지 재생** —
   `forge motion play --slot 100 --port /dev/...` (현재 미구현, 후속 Sprint).

3. **즉시 모니터** —
   - 모터 온도 (`forge joint state` 폴링)
   - 자세 (visual)
   - 비정상 소리 / 진동

4. **재생 완료 후** —
   ```bash
   forge joint torque --port /dev/... --all --off  # 토크 OFF
   ```

### 비상 절차

- **e-stop** 즉시 `forge joint estop --port /dev/...` 또는 ⌘⇧. SwiftUI 단축키
- **낙상 시** — 사용자 직접 robot 들어올림, **전원 OFF** 권장
- **모터 과열 (>60°C)** — 즉시 토크 OFF + 10 분 휴식

---

## 자동화 가능 / 자동화 불가

| 단계 | 자동화 |
|------|--------|
| G1 Static validation | **완전 자동** (`forge synth validate` / MCP `validate` 도구) |
| G2 연결 확인 | **반자동** (`forge connect` + 사용자 시각 확인) |
| G2 Dry-run 송출 | **미구현** — Sprint 13 후속 |
| G3 walk-ready | **반자동** (`forge walk-ready` 명령) |
| G3 페이지 재생 | **미구현** — Sprint 13 후속 |
| 비상 절차 | **사용자 책임** (인간 안전 critical) |

---

## Validator Calibration 데이터 수집 (PRD §17.4)

V1 JointLimit / V2 Velocity 임계 정합성 보강을 위해 **실 robot 측정 데이터** 수집:

### 데이터 수집 protocol

1. Robot 을 walkReady 자세로 이동 (G3-1).
2. 토크 OFF 상태에서 사용자가 직접 robot 의 각 관절을 max 범위까지 천천히 회전.
3. `forge joint state --id <n>` 으로 raw 값 polling (10 Hz).
4. 각 관절의 min / max raw 측정.
5. 결과를 `docs/architecture/joint-limits-measured.md` 에 기록.

### V2 calibration

ROBOTIS motion_4096.bin 의 모든 페이지에서 max velocity 측정 완료 (2026-05-12):
- p99: 4.74 raw/ms
- max: 10.26 raw/ms (page 12 right kick R_ANKLE_PITCH)
- WARN 임계: 5.2 raw/ms
- FAIL 임계: 11.3 raw/ms

후속: 실 robot 에서 측정된 max velocity (motor sysfs 또는 measured slip) 로 추가 보정.

---

## 사용자 체크리스트 (참고용 short form)

```
□ G1 validate PASS 또는 WARN-with-justification
□ G2 connect 정상 (CM 보드 + 20 모터 + 배터리 ≥ 11V + 온도 ≤ 50°C)
□ G2 토크 OFF 물리 확인
□ G3 안전 사전 점검 5 항목 모두 ✓
□ G3 walkReady 부드러운 진입 확인
□ G3 사용자 명시 동의 ("실행 OK")
□ 재생 후 토크 OFF + 모터 휴식
□ 사고 시 e-stop + 전원 OFF + 카메라 영상 보존
```

## 책임 한계

본 문서는 **참고용 protocol** 이며 실제 robot 손상 / 사고 시 책임은 운영자에게
있습니다. ROBOTIS 공식 maintenance guide 와 함께 사용하세요.

ROBOTIS 공식 자료:
- `DARwIn-OP_ROBOTIS_v1.6.0/Linux/README.txt`
- `e-Manual` (online)
- `research/robotis-official/ROBOTIS-OP2/op2_manager/` 디렉토리

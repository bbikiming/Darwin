# Anbernic RG G01 동글 직결 조종 감사 — 안정성·반응성 개선 제안

- 일시: 2026-06-14
- 범위: RG G01 2.4G 동글 → 로봇 USB → `GamepadPilot` → `WalkLabBrokerage` → ROBOTIS `Walking`
- 주요 파일: `firmware-patches/walklab-brokerage/GamepadPilot.{h,cpp}`,
  `firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp`,
  `firmware-patches/walklab-brokerage/WalkLabTransport.{h,cpp}`,
  `docs/design/handheld-direct-pilot-upgrade.md`,
  `docs/design/anbernic-gait-upgrade.md`,
  `docs/reports/2026-06-12-rgg01-usb-probe.md`,
  `docs/reports/2026-06-13-rgg01-bringup.md`

## 0. 결론

현재 구현은 "보여주기식" 수준은 아니다. H0 실측, P7 실기 브링업, 호스트 단위 테스트,
E-STOP 복구 결함(F9) 수정까지 이어진 실제 구현이다. 구조적으로도 동글 직결의 장점
(네트워크 홉 제거, 로컬 E-STOP, 로봇측 거버너/슬루 일원화)을 살리고 있다.

다만 실기 조종을 더 빠릿하고 안전하게 만들려면 아래 4가지를 우선 고쳐야 한다.

1. 유휴 상태 첫 입력이 최대 100ms까지 늦을 수 있는 supervisor sleep 정책
2. 외부 UDP/Switch/Mac E-STOP이 `GamepadPilot`의 ARM 상태를 disarm하지 않는 문제
3. 노드 소멸 처리에 남아 있는 "LB=데드맨" 시절 조건
4. 순수 좌우 보행의 gait 강도 과소평가(`y`를 28mm가 아닌 38mm 기준으로 정규화)

문서도 정리 필요하다. `implementation-prompts.md`는 EVIOCGKEY 폐기를 반영했지만,
`handheld-direct-pilot-upgrade.md` 본문과 리스크 표에는 EVIOCGKEY/LB 데드맨/RB 터보 전제가
남아 있다. 다음 구현 세션이 이 문서를 복붙하면 현재 코드와 다른 방향으로 작업할 수 있다.

## 1. 현재 잘 된 부분

| 항목 | 판정 | 근거 |
|---|---|---|
| 동글 기본 경로 | 타당 | H0에서 XInput `045e:028e`, xpad 네이티브 바인딩 확인. 이름+VID/PID 재스캔 구현 |
| 로컬 E-STOP | 타당 | B 버튼은 슬롯 경유 없이 reader thread에서 `TriggerEstopImmediate` 호출 |
| B 스테일 면역 | 좋음 | release 유실 시에도 B value=1이면 무조건 E-STOP 발화 |
| 로봇측 최종 거버너 | 좋음 | `GovernEnvelope`, `SlewToward`, `GateSchedule`이 모든 소스에 적용 |
| 좌우/회전 개선 기반 | 상당 부분 완료 | side 28, turn 18, DY 7, DA 6, gate-on-y, co-arrival slew 적용 |
| 테스트 | 좋음 | `test_transport` 187 checks, `test_gamepad` 216 checks 모두 0 failure |

## 2. 우선 수정 권장 사항

### P0-1. 유휴 상태 첫 입력 지연: 최대 100ms sleep

현재 supervisor는 보행 중이거나 `local_fresh`일 때만 20ms로 돈다. `local_fresh`는 마지막
이벤트가 1초 이내일 때만 true다.

- `WalkLabBrokerage.cpp`: `sleep_ms = (walking_active || local_fresh) ? 20 : 100`
- `GamepadPilot::HasControl`: `now_ms - m_last_event_ms <= 1000`

문제는 1초 이상 입력이 없던 뒤 첫 스틱 이벤트다. reader thread가 이벤트를 받아 슬롯에
넣어도 supervisor가 이미 100ms sleep에 들어간 직후라면 첫 명령 적용은 최악 100ms 늦는다.
F11 코멘트는 "첫 스틱 입력 평균 50ms → 10ms" 의도지만, 현재 구조만 보면 첫 이벤트 자체로
supervisor를 깨우지는 못한다.

권장 수정:

1. 최소 변경: `m_gamepad.DevicePresent()`가 true면 유휴도 20ms loop로 유지한다.
   - 장점: 구현이 작고 즉시 p95 개선
   - 비용: 패드 연결 중 유휴 CPU 증가. 기존 실측 load avg ~0.8-0.9라 감당 가능성 높음
2. 더 좋은 변경: `GamepadPilot`이 local slot에 새 라인을 offer할 때 self-pipe/eventfd로
   supervisor sleep을 깨운다.
   - 장점: CPU 절약과 즉시성을 모두 만족
   - 비용: C++03/POSIX 배선과 종료 처리 테스트 필요

검증:

- evdev 이벤트 수신 시각 → `ApplyCommandLine` 시각을 로봇 로그로 찍어 idle 첫 입력 p95를 측정
- 목표: idle 첫 입력 p95 <= 40ms, worst <= 60ms

### P0-2. 외부 E-STOP이 GamepadPilot ARM을 해제하지 않음

`TriggerEstopImmediate()`는 UDP E-STOP과 Gamepad B가 공유한다. 하지만 실제 disarm은
Gamepad B 경로의 `ProcessEvent` 내부에서만 `m_armed=false`로 처리된다. UDP/Switch/Mac
E-STOP은 물리 정지와 flag latch는 수행하지만 `GamepadPilot` 내부 ARM 상태를 직접 끄지 않는다.

위험 시나리오:

1. RG G01로 A ARM 후 스틱을 잡고 있음
2. Switch/Mac/UDP에서 E-STOP
3. 로봇은 flag 때문에 멈춤
4. flag가 해제되면 GamepadPilot은 여전히 armed일 수 있음
5. 남아 있는 스틱 상태/다음 refresh/event로 즉시 재보행 가능

권장 수정:

- `GamepadPilot::ForceDisarm()` 같은 thread-safe public method 추가
- `WalkLabBrokerage::TriggerEstopImmediate()`에서 항상 `m_gamepad.ForceDisarm()` 호출
- MODE 버튼 종료, 낙상/getup 진입처럼 안전상 "새 의도 필요" 구간에도 같은 disarm을 검토

검증:

- 테스트 추가: gamepad ARM → external estop trampoline/브로커리지 helper 호출 → flag clear 후
  A 재입력 전에는 스틱 이벤트가 enabled=0이어야 함
- 실기: Switch E-STOP 후 G01 스틱 유지 상태에서 Y/flag clear만으로 재보행하지 않는지 확인

### P0-3. 노드 소멸 처리에 남은 LB 데드맨 조건

F10/F12 이후 LB는 데드맨이 아니라 왼발 킥이고 `GP_DEADMAN_REQUIRED=false`다. 그런데
`HandleNodeLost()`는 여전히 `!m_snap.btn_lb`이면 최종 정지 라인을 발행한다.

현재 효과:

- LB 미누름 상태에서 노드 소멸: `m_armed=false` 후 `OfferCurrentLocked()` → `enabled=0`
  라인 발행 → supervisor가 `Walking::Stop()`으로 즉시 정지할 수 있음
- LB 누름 상태에서 노드 소멸: 라인 미발행 → H2 ②티어가 목표 0 슬루로 완만 정지

이는 버튼 의미론과 안전 의미론이 어긋난 상태다. "LB를 누르고 있었는가"가 단절시 정지
방식(즉시 Stop vs 완만 슬루)을 결정하면 안 된다.

권장 수정:

- F10 이후 기준으로 `HandleNodeLost()`는 노드 소멸 시 최종 `enabled=0` 라인을 발행하지 않고,
  항상 `PollFailsafe()`의 ②티어가 목표 0 슬루를 소유하도록 단순화한다.
- 단, E-STOP은 별도 즉시 정지 경로를 유지한다.
- 주석과 테스트명에서 "deadman held" 용어 제거. "node lost with/without release synthesis"로
  다시 정의한다.

검증:

- `test_pilot_tier1_release_then_enodev`, `test_pilot_tier2_enodev_without_release`,
  `test_pilot_tier2_enodev_deadman_held` 재작성
- 노드 소멸 후 `TakeCommand()`가 stop line을 내지 않고 `PollFailsafe()==GP_FS_SLEW_ZERO`인지 확인
- 실기: 동글 뽑기/전원 OFF/거리 이탈에서 즉시 관절 Stop이 아니라 목표 0 ramp-down인지 확인

### P1-1. 순수 좌우 보행 gait 강도 과소평가

`GpGaitSchedule()`은 `y`도 `GP_MAX_STRIDE_MM(38)`로 정규화한다.

현재 상수:

- `GP_MAX_STRIDE_MM = 38`
- `GP_MAX_SIDE_MM = 28`

따라서 순수 좌우 풀스틱은 실제로 최대치인데도 강도는 `28/38 = 0.7368`로 계산된다.
`intensity^0.7` 이후에는 다음처럼 된다.

| 입력 | 현재 intensity | 현재 period/foot | side cap 기준 제안 |
|---|---:|---:|---:|
| 순수 좌우 풀스틱 28mm | 0.7368 | 586.9ms / 35.8mm | 560.0ms / 40.0mm |
| 순수 좌우 반스틱 14mm | 0.3684 | 630.4ms / 28.9mm | 613.8ms / 31.5mm |

체감상 좌우가 덜 빠릿하고 발 클리어런스도 덜 받는 원인이 될 수 있다. `GateSchedule`은
이미 `ENVELOPE_Y_MAX`를 쓰도록 개선됐으므로, gait schedule도 축별 cap으로 맞추는 편이
논리적으로 일관된다.

권장 수정:

```cpp
double yi = fabs(y_mm) / GP_MAX_SIDE_MM;
```

검증:

- `test_gait_schedule`에 순수 side full/half 케이스 추가
- 온스탠드 측보에서 foot/z_move 증가가 IK freeze를 만들지 않는지 확인

### P1-2. local 제어권 1초와 refresh 1.5초의 불일치

`MaybeRefresh()`는 마지막 이벤트 후 1.5초까지 50ms마다 보유 상태를 재공급한다. 반면
supervisor의 `local_control`은 마지막 이벤트 후 1초까지만 true다.

결과:

- 1.0초 이후 1.5초 전까지 GamepadPilot은 명령을 계속 만들지만 supervisor가 drain만 하고 적용하지 않음
- 이 구간에 UDP/파일 명령이 들어오면 네트워크가 제어권을 가져갈 수 있음
- 정적 스틱 hold 보행 중 Mac의 enabled=0 파일이 선점하는 잔여 리스크와 연결됨

권장 수정:

- "제어권 신선도"와 "링크 생존 추정"을 분리한다.
- 최소 변경: local control window를 `GP_SILENCE_SLEW_MS`와 맞춰 1500ms로 늘린다.
- 더 좋은 변경: `m_last_offer_ms` 또는 "refresh가 실제로 발행 중인지"를 기준으로
  `HasControl()`을 true로 유지하되, 1.5초 silence 이후에는 false로 떨어뜨린다.

검증:

- 정적 스틱 hold 1.2초 시점에서 local refresh 라인이 실제 적용되는지 테스트
- 네트워크 파일 enabled=0이 local hold를 1초 지점에 선점하지 않는지 테스트

### P1-3. 데드맨 제거 후 ARM이 무기한 유지됨

현재 이동 게이트는 ARM 단일이다. 이는 조작감은 좋지만 안전상 "A 한 번 누르면 계속 무장"이다.
패드가 손에 들려 있지 않거나, 스틱이 치우친 상태에서 건드려도 움직일 수 있다.

권장 수정 옵션:

1. `GP_ARM_IDLE_TIMEOUT_MS` 추가: 이동 입력/버튼 입력이 일정 시간 없으면 자동 disarm
2. `START` 또는 `BACK`을 "hold-to-drive"나 "drive enable" 보조 안전 버튼으로 할당
3. UI/운용 규칙으로만 처리하지 말고 TEL2에 `armed` 상태를 노출해 관찰 가능하게 만든다

권장 우선순위는 1이다. 데드맨을 되살리면 조작감이 크게 바뀌므로, 우선 idle timeout이
현실적인 절충이다.

검증:

- ARM 후 `N`초 무입력 → 스틱 입력 enabled=0
- timeout 직전/직후 버튼 입력으로 의도치 않은 재ARM이 없는지 확인

### P1-4. ③티어 silence 임계는 아직 설계값이다

`GP_SILENCE_SLEW_MS=1500`은 안전 측 초기값이지 확정값이 아니다. H0/H7 실기 기록에서도
정속 직진 이벤트 침묵 분포는 미측정으로 남아 있다.

권장 실측:

- 크래들 위에서 full/half forward, full/half side, full/half turn 각각 60초
- evdev SYN/ABS gap p50/p95/max, supervisor `active_source`, `loop_ms`, `x/y/a_lat` 동시 기록
- `max normal gap * 2`와 비정상 단절 검출 목표 사이에서 임계 재선정

판정 기준:

- 정상 hold gap p99가 1.5초에 근접하면 현재 임계는 오발 위험
- 비정상 RF 단절이 node lost 없이 침묵한다면 임계는 길게 늘리면 위험
- 둘이 충돌하면 deadman 대체 안전장치(ARM timeout 또는 hold-to-drive)를 넣어야 한다

## 3. 문서 정합성 수정 필요

다음 문장은 현재 구현과 다르거나 실측으로 폐기됐다.

| 문서 | 문제 |
|---|---|
| `handheld-direct-pilot-upgrade.md` H1-1 | EVIOCGKEY 1s 상태 폴 병행이라고 되어 있음. H0 이후 폐기됨 |
| `handheld-direct-pilot-upgrade.md` H1/H2 | LB=데드맨, RB=터보, 콕핏 1:1 매핑이 남아 있음. 현재는 LB/RB 킥, LT/RT 회전, 우스틱 헤드 |
| `handheld-direct-pilot-upgrade.md` 리스크 표 | 3중 failsafe에 EVIOCGKEY 폴이 남아 있음 |
| `implementation-prompts.md` P7 본문 | 완료 블록은 최신에 가깝지만 코드 블록 내부는 초기 P7 지시문이라 F10/F12 이후와 다름 |
| `GamepadPilot.h` 상단 주석 | "콕핏 RG G01 프리셋과 1:1 의미론"이라고 되어 있으나 F10에서 의도적으로 이탈 |

문서 정리 원칙:

- 구현이 맞으면 문서를 고친다. 현재는 코드가 실기 피드백을 더 많이 반영하고 있다.
- "H0/P7 초기 설계"와 "F10/F12 현재 조작계"를 분리해서 기록한다.
- 다음 복붙 프롬프트는 EVIOCGKEY/LB 데드맨/RB 터보를 다시 지시하지 않게 한다.

## 4. 권장 구현 순서

### Batch A — 안전 의미론 정리

1. `GamepadPilot::ForceDisarm()` 추가
2. `TriggerEstopImmediate()`에서 모든 E-STOP 소스에 대해 ForceDisarm 호출
3. `HandleNodeLost()`에서 LB 조건 기반 stop line 제거
4. local control window와 silence/refresh window 정렬
5. 관련 host tests 재작성

예상 효과:

- 외부 E-STOP 후 재보행은 항상 명시적 A ARM 필요
- node lost는 버튼 상태와 무관하게 같은 방식으로 완만 정지
- 정적 hold 중 Mac/파일 명령 선점 감소

### Batch B — 반응성 개선

1. supervisor idle sleep을 gamepad present/armed 상태에서 20ms로 유지하거나 self-pipe wake 추가
2. `GpGaitSchedule`의 side 정규화 denominator를 `GP_MAX_SIDE_MM`로 변경
3. idle 첫 입력, pure side, diagonal side+turn 실기 벤치

예상 효과:

- 유휴 첫 스틱 입력 worst-case 100ms 제거
- 좌우 보행의 period/foot이 입력 강도와 맞아 더 빠릿하게 반응

### Batch C — 문서/실기 게이트

1. `handheld-direct-pilot-upgrade.md`, `implementation-prompts.md`, `GamepadPilot.h` 주석 최신화
2. 단절 매트릭스 4종: 전원 OFF, 거리 이탈, 배터리 탈락, 동글 뽑기
3. 10분 CPU/loop_ms 분포
4. E-STOP 물리 정지 완료 타임스탬프
5. silence gap 분포로 `GP_SILENCE_SLEW_MS` 확정

## 5. 완료 판정 기준

수정 후 "동글 직결 조종이 충분히 안정적이고 빠릿하다"고 말하려면 최소 아래 증거가 필요하다.

- host: `make -C firmware-patches/walklab-brokerage/tests` green
- 로봇 idle 첫 입력: p95 <= 40ms
- B/UDP/Switch/Mac E-STOP: flag 생성뿐 아니라 물리 정지 완료 시간 기록
- 외부 E-STOP 후 A 재ARM 전 재보행 불가
- node lost 모든 케이스에서 동일한 tier 동작 확인
- pure side full input에서 목표 period/foot이 설계값과 일치
- 10분 조종 중 loop_ms, CPU, 카메라 동시 부하 이상 없음
- 현재 문서에 EVIOCGKEY/LB 데드맨/RB 터보 같은 폐기 전제가 남지 않음

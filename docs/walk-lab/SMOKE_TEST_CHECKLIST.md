# 실 robot smoke test 체크리스트

> **목적**: `scripts/smoke/*.sh` 가 자동화하지 못하는 시각 / 청각 / 촉각 검증 항목.
> 자동화 가능한 부분은 script 가 처리하고, 본 checklist 는 사용자가 직접 robot
> 옆에서 확인해야 하는 항목만 추렸다. 자동화 script 실행과 병행해서 사용.
>
> **처음 사용자는 먼저** → [SMOKE_USER_GUIDE.md](SMOKE_USER_GUIDE.md) (사전 준비
> + 4 phase 실행 절차 + 트러블슈팅 10건). 본 체크리스트는 그 가이드의 §3 (수동
> 검증) 에 대응.
>
> **연관 docs**:
> - [SMOKE_USER_GUIDE.md](SMOKE_USER_GUIDE.md) — 사용자 협업 가이드 (사이클 281)
> - [USER_PILOT_GUIDE.md](USER_PILOT_GUIDE.md) — 5 입력 source 사용법
> - [../harness/real-robot-verification.md](../harness/real-robot-verification.md) — 텔레메트리 검증 절차
> - [../harness/walklab-gyro-smoke-test-2026-05-23.md](../harness/walklab-gyro-smoke-test-2026-05-23.md) — 자이로 보정 시나리오
>
> **사이클 275 (V275-4)**: 자동 script + 수동 checklist 분리.
> **사이클 281 (V281-4)**: dry-run 검증 + SMOKE_USER_GUIDE.md cross-reference 추가.

---

## 비유

새 차 시운전 — 계기판 (script 의 자동 점검) 은 자동으로 읽지만, **핸들 떨림 /
브레이크 감 / 엔진 소음** 은 운전자 본인이 직접 느껴봐야 안다. 본 checklist
는 후자.

## 결론 한 줄

**자동 script 가 GREEN 이라도 본 checklist 의 모든 항목을 직접 확인해야
"smoke test PASS"**. 사람 감각이 detector 인 항목들.

---

## 사용 방법

```bash
# 1. 환경 변수 설정 (한 번)
export ROBOTIS_HOST=192.168.123.1
export ROBOTIS_USER=robotis
export ROBOTIS_SSH_KEY=~/.ssh/id_ed25519   # 선택

# 2. 자동 + 반자동 script 실행
bash scripts/smoke/run-all-smoke.sh

# 3. script 가 PASS 떨어지면 본 checklist 의 각 항목 직접 확인
```

각 항목 옆 `[ ]` 를 사용자가 manual 로 채운다. ✓ = 정상, ✗ = 이상, ? = 판단
유보. 단 1개라도 ✗ 면 robot 사용 중단 후 원인 추적.

---

## A. 사전 안전 (preflight-check.sh 와 함께)

- [ ] robot 이 **정비 스탠드** 위에 거치되어 있는가?
- [ ] **발이 지면에 닿지 않는가**? (붕 떠 있어야 안전)
- [ ] 비상정지 키 (Space) 또는 H/W 버튼이 손이 닿는 거리에 있는가?
- [ ] 충돌 가능 물체가 robot 반경 50cm 이내에 없는가?
- [ ] 배터리 잔량 표시가 11.1 V 이상인가? (10.5 V 미만이면 보행 금지)
- [ ] 케이블 (USB / 이더넷 / 전원) 이 robot 동작에 걸리지 않는가?
- [ ] 정전기 / 액체 / 열원 근처가 아닌가?

## B. 앱 시동 + 연결 (deploy-and-verify.sh 와 함께)

- [ ] DarwinForge 창이 5초 안에 떴는가?
- [ ] Dock 의 DarwinForge 아이콘이 정상 표시되는가? (깨짐 / placeholder X)
- [ ] 메뉴바의 모든 메뉴가 클릭 가능한가? (회색 / hang X)
- [ ] 사이드바의 "Auto Connect" 버튼이 한 번 클릭으로 응답하는가?
- [ ] 연결 시도 중 "스피너" 가 표시되는가?
- [ ] 연결 성공 시 status indicator 가 녹색이 되는가?
- [ ] 연결 실패 시 사용자에게 명확한 오류 메시지가 보이는가?

## C. 첫 자세 (standing) 검증

> **주의**: 자세 적용은 motor 에 torque 를 거는 작업. 정비 스탠드 위에서만.

- [ ] standing 자세 적용 후 **robot 의 hip / knee / ankle 가 정확한 각도**로
      움직였는가? (한쪽만 회전 X)
- [ ] 자세 적용 중 **이상 고주파 모터 음** 없는가? (정상은 가벼운 servo 톤)
- [ ] 자세 유지 시 **떨림 / 진동** 없는가? (정지 상태에서 motor 가 가만히)
- [ ] 좌우 대칭이 시각적으로 맞는가? (한쪽 다리만 살짝 안쪽 / 바깥 X)

## D. WalkLab — Mac sparse 모드

- [ ] preset "march" Start 시 첫 step 이 **부드럽게** 시작되는가?
      (덜컥 / jolt X)
- [ ] hip / knee 의 각도 변화가 **양쪽 다리 시간 일치** 하는가?
- [ ] preset "slowWalk" → "fastWalk" 전환 시 **속도 변화가 즉시** 반영되는가?
- [ ] balance corrector ON 상태에서 **외력으로 robot 살짝 기울이면**
      ankle / hip roll 이 반대 방향으로 보정하는가?
- [ ] HUD 의 **imuRollDeg / pitchDeg 값**이 실 자세 변화와 일치하는가?
      (왼쪽 기울이면 + 또는 -; 의도된 sign convention 일치)
- [ ] **IMU stale badge** (orange / red) 가 케이블 단선 시 표시되는가?
- [ ] **stale 복구 후 badge 사라짐**?

## E. WalkLab — Onboard 모드

- [ ] OnboardHealthIndicator 카드가 표시되는가?
- [ ] daemon 이 v1 인 경우 ⚠ warning banner 가 표시되는가?
      (자동: `walk-cycle-smoke.sh` 가 schema 감지)
- [ ] "v2 확인" 버튼 클릭 시 banner 가 사라지는가?
- [ ] preset 전환 시 robot 의 다리 패턴이 **즉시** 바뀌는가?
- [ ] balance 토글 ON 시 robot 측 `walking_engine_command` 의 9번째 필드가
      "1" 로 갱신되는가? (자동: `walk-cycle-smoke.sh` 가 검증)

## F. 비상정지 + 복구 (recovery-smoke.sh 와 함께)

- [ ] **Space 키 누른 즉시 (< 200 ms) torque release click 소리** 들리는가?
- [ ] **모든 motor 가 동시에** torque OFF 되는가? (한쪽만 X)
- [ ] 비상정지 후 **팔 / 다리가 자유롭게 swing** 하는가?
- [ ] 화면에 "비상정지 활성" 배너가 표시되는가?
- [ ] **R 키 / START 버튼** 누르면 복구 배너 / 상태 변경 시각 확인?
- [ ] 복구 후 **다음 preset 명령에 정상 반응** 하는가?

## G. UI 인터랙션 (TelemetryHarness 와 함께)

- [ ] Inspector → 텔레메트리 탭의 "진행 중" 표시가 녹색?
- [ ] Live tail 이 1초마다 새 이벤트로 갱신?
- [ ] HUD 가 **5 Hz idle / 20 Hz walk** 로 자동 전환?
      (자동: deploy-and-verify.sh / walk-cycle-smoke.sh 가 polling rate 변경
      이벤트 검증)
- [ ] 비상정지 발화 시 "에러 둘러보기 (N)" 카운터 증가?
- [ ] 사이드바 / `⌘1..7` / 메뉴 의 section 전환이 즉시 반응?

## H. 종료 절차

- [ ] DarwinForge 종료 시 robot 의 motor 가 안전 자세 (sitDown 또는 idle) 로?
- [ ] 종료 후 robot 의 motor 가 silent torque-off 상태?
- [ ] 다음 시동 시 이전 세션이 `sessions/<UUID>/` 로 archive 됐는가?
      (자동: `deploy-and-verify.sh` 가 다음 실행에서 검증)

---

## 실패 시 대응

| 증상 | 즉시 조치 | 분석 자료 |
|---|---|---|
| robot 이 떨어졌다 | E-stop → 배터리 분리 → 본 checklist 처음부터 | Inspector → 마지막 5분 이벤트 export |
| motor 비정상 진동 | 즉시 비상정지 → 해당 motor 점검 | dxl_scan.sh + 모터 별 ping |
| balance 보정 방향 반대 | preset.idle → rollInputConvention 토글 | imuRollDeg 값 + lastCorrections 비교 |
| 비상정지 후 motor 미해제 | 배터리 분리 (마지막 수단) | bus.e_stop + bus.write_fail 이벤트 검사 |
| IMU stale 영구 | 케이블 재연결 → robot 재부팅 | imu.stale 이벤트 + sysfs/iio_imu 확인 |

---

## 결과 기록

본 checklist 의 결과를 다음 형식으로 저장 권장:

```
docs/harness/smoke-test-results-YYYY-MM-DD.md
```

각 섹션 (A-H) 별 ✓ / ✗ + 사이클 / 빌드 / 사용자 ID + 자유 노트.

---

## 한계

- **모든 motor 의 미세 진동 측정** — 사람 청각의 한계. 가속도계 부착 시 자동
  화 가능 (현재 미구현).
- **robot 이 떨어졌는지 자동 감지** — IMU fall detector 가 일부 cover 하지
  만, "stand 자세에서 가만히 있는데 한쪽으로 살짝 기울었다" 같은 미세 상태
  는 사람이 직접 봐야 한다.
- **시각적 좌우 대칭** — vision-based 자동화는 별도 카메라 + 모델 필요.

본 checklist 는 **사용자 1명 + robot 1대** 의 단일 세션 기준. CI 자동화 별도.

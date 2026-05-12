# Walk Progression Test — Sprint 5 walk-engine 진입 전 검증 절차

> 6 페이지 (110~115) 의 점진적 보행 테스트 모션. NimbRo·ENS reference 의 알고리즘을 우리
> walk-engine 으로 옮기기 **전**에, "스톡 walkready 에서 얼마나 안전하게 벗어날 수 있는가"
> 를 페이지 단위로 검증한다.
>
> 모션 파일: [`motions/test/walk-progression-v1.bin`](../../motions/test/walk-progression-v1.bin)
> 가독 spec: [`motions/test/walk-progression-v1.json`](../../motions/test/walk-progression-v1.json)
> 생성 스크립트: [`scripts/research/generate_walk_test_motion.py`](../../scripts/research/generate_walk_test_motion.py)

## 1. 설계 의도

이 6 페이지는 **walk-engine 자체가 아니다.** Action 페이지 단위로:

1. 스톡 `walkready` 의 정확한 관절 값에서 출발 (검증된 기준점).
2. 각 페이지는 정확히 **한 가지 motion primitive 만 격리**해서 테스트.
3. 모든 페이지가 walkready 에서 시작/종료 → 어느 페이지가 실패해도 다음 시작점 동일.
4. 모든 페이지 `exit=15 (sit_down)` → Ctrl+C 또는 Stop() 시 안전한 sit 자세로 종료.
5. 위험도 오름차순으로 실행하면, 어떤 primitive 에서 문제가 발생했는지 정확히 분리 가능.

이게 통과해야 Sprint 5 의 walk-engine (LIPM + balance gain + smooth start) 통합 테스트로
넘어간다.

## 2. 페이지 요약

| # | 이름 | 위험도 | 핵심 검증 항목 | 변화 관절 | Δmax |
|--:|-----|--------|----------------|----------|------|
| 110 | `wk_hold` | very-low | 서보 명령 도달 + walkready pose 안정성 (2 s hold) | — | 0° |
| 111 | `wk_arms` | very-low | 비-다리 관절 servo command path | `L_SHOULDER_PITCH`, `R/L_ELBOW` | 15° |
| 112 | `wk_knee` | low | 다리 서보 부하 + 조정 운동 (squat 3°) | hip_pitch / knee / ankle_pitch 6 개 | 3° |
| 113 | `wk_hip_r` | low | 측면 CoM 이동 (발 고정) | `R/L_HIP_ROLL` | 2.5° |
| 114 | `wk_hip_l` | low | 113 의 좌우 미러 | `R/L_HIP_ROLL` | 2.5° |
| 115 | `wk_lean_pitch` | medium | pitch 축 IMU 피드백 + ankle 보상 | hip_pitch / ankle_pitch 4 개 | 2° 전/후 |

> `R_SHOULDER_PITCH` (ID 1) 은 stock walkready 에서 `0x4000 (INVALID)` — Walking 모듈이
> 소유. 우리 테스트 페이지는 이 관절을 건드리지 않는다 (walkready 와 동일 INVALID 유지).

## 3. 사전 준비 — 무조건 체크

다음 5 항목 중 하나라도 미흡하면 **테스트 시작 금지**:

- [ ] **백업** — 기존 `/darwin/Data/motion_4096.bin` 을 `motion_4096.bin.bak.YYYYMMDD-HHMMSS` 로 보존했다.
- [ ] **거치** — 로봇이 정비 스탠드에 고정 거치되어 있거나, 손으로 잡을 사람이 옆에 있다.
- [ ] **배터리** — LiPo 11.1 V 풀충전 (또는 외부 어댑터 12 V 안정 공급).
- [ ] **펌웨어** — CM-730/740 펌웨어 정상 (`dxl_monitor` 로 ID 1..20 모두 ping 통과).
- [ ] **offset** — `offset_tuner` 마지막 캘리브레이션이 1 주 이내. 또는 walkready 자세 시
      양 발바닥이 평면에 ±2 mm 이내 접지.

추가로:
- 페이지 12 (rk), 13 (lk) 등 위험 페이지는 **이 테스트가 끝날 때까지 실행 금지** — 서보·
  바닥·구조 모두 사전 검증 안 된 상태.
- 테스트 중에는 **항상 손이 비상 정지 (전원 차단 or `Ctrl+C`) 가능한 위치**.

## 4. 모션 파일 배포

옵션 A — **권장**: 별도 슬롯 사용. 기존 motion_4096.bin 은 그대로 두고, 우리 빌드의 slot
110~115 만 덮어쓴다.

```sh
# 0. SSH 로 로봇 접속
ssh darwin@192.168.1.101

# 1. 백업
cp /darwin/Data/motion_4096.bin \
   /darwin/Data/motion_4096.bin.bak.$(date +%Y%m%d-%H%M%S)

# 2. 우리 파일 전송 (Mac 측)
scp motions/test/walk-progression-v1.bin darwin@192.168.1.101:/darwin/Data/

# 3. (옵션) 페이지 110..115 만 in-place 패치하고 싶다면:
#    dd if=walk-progression-v1.bin of=/darwin/Data/motion_4096.bin \
#       bs=512 skip=110 seek=110 count=6 conv=notrunc
#    위 명령은 새 파일에서 110..115 번 페이지 (각 512 byte) 만 잘라 기존 파일에 덮어쓴다.

# 4. action_editor 로 검증
cd /darwin/Linux/project/action_editor
sudo ./action_editor /darwin/Data/walk-progression-v1.bin   # 별도 파일로 실행
# 또는 기존 파일에 in-place 패치한 경우:
# sudo ./action_editor /darwin/Data/motion_4096.bin
```

## 5. 페이지별 실행 + 합격 기준

### Page 110 — `wk_hold` (very-low)

```text
action_editor> page 110
action_editor> play
```

| 항목 | 합격 |
|------|------|
| 진입 시간 | 1 s 이내에 walkready 자세로 진입 |
| 정지 hold | 2 s 동안 같은 자세 유지, 가시적 진동 없음 |
| IMU pitch | |값| ≤ 5° |
| IMU roll | |값| ≤ 5° |
| 종료 | 자동 정지 (next=0) |
| 모터 온도 | 어느 모터든 +5 °C 이상 상승 없어야 |

**실패 → 즉시 정지. 진단:**
- 진입 자체가 안 되면: CM 시리얼 / 서보 ID / 전원 문제.
- 진동 발생: PID 게인 (`Linux/build/Walking.cpp::P_GAIN_RATIO`) 확인.
- IMU 큰 값: 캘리브레이션 (offset_tuner 재실행).

### Page 111 — `wk_arms` (very-low)

```text
action_editor> page 111
action_editor> play
```

| 항목 | 합격 |
|------|------|
| 팔 이동 | L_SHOULDER_PITCH 약 -10°, 두 elbow 약 ±15° 굽힘이 보임 |
| 다리 | 완전히 정지 (가시적 움직임 0) |
| 종료 후 | 정확히 walkready 로 복귀 |
| IMU | 변화 ≤ 5° |

**실패 → 진단:**
- 다리에 미세 진동 → 자세에 영향 없음, 통과 가능.
- 팔이 안 움직임 → 해당 모터 ID 의 컨트롤 테이블 (특히 `Torque Enable=1`) 확인.

### Page 112 — `wk_knee` (low)

```text
action_editor> page 112
action_editor> play
```

| 항목 | 합격 |
|------|------|
| 무릎 굽힘 | 양 무릎이 동시·동일 각도로 ~3° 굽혀짐 |
| 토르소 | **수직 유지** (앞으로 기우는 게 보이면 ankle_pitch 보상 부족) |
| 복귀 | walkready 정확 복귀 |
| IMU pitch | 굽힘 시 ≤ 8°, 복귀 후 ≤ 5° |
| 모터 온도 | knee (ID 13, 14) 가장 부하 — +10 °C 이상 상승 시 중단 |

**실패 → 진단:**
- 토르소가 앞으로 기움: ankle_pitch 보상값을 page JSON 에서 1.5° → 2.0° 로 증가 후 재생성.
- 다리가 떨림: speed (32 → 24), accel (32 → 16) 으로 천천히 재생성.

### Page 113 — `wk_hip_r` (low)

```text
action_editor> page 113
action_editor> play
```

| 항목 | 합격 |
|------|------|
| 토르소 이동 | 시각적으로 우측 sway 가 보임 (~2 cm 측면 이동) |
| 발바닥 | **양 발 모두 평면 접지 유지** — 한 쪽 들리지 않음 |
| IMU roll | 우측으로 5~7°, 복귀 후 ≤ 5° |
| 복귀 | walkready 정확 복귀 |

### Page 114 — `wk_hip_l` (low)

Page 113 의 좌우 미러. 같은 합격 기준, IMU roll 좌측 5~7°.

> **113 OK + 114 OK** 시점에 단순 lateral CoM 이동이 안정 — 이후 walk-engine 의 single-foot
> support 단계로 넘어갈 수 있는 신호.

### Page 115 — `wk_lean_pitch` (medium)

```text
action_editor> page 115
action_editor> play
```

| 항목 | 합격 |
|------|------|
| Forward lean | 2° 앞으로 기울었다가 복귀 |
| Backward lean | 2° 뒤로 기울었다가 복귀 |
| IMU pitch | forward 시 +5~10°, backward 시 -5~10° |
| 양 발 | 평면 접지 유지 |
| **abort 임계** | **IMU pitch 절대값 25° 초과 → 즉시 Ctrl+C** |

**이 페이지가 walk-engine pitch balance 의 진실 측정점.** 통과하면 NimbRo `lean_fb_gain`,
`balance_angle_smooth_gain` 튜닝의 baseline 확보.

## 6. 데이터 수집

각 페이지 실행 시 다음을 기록 (Mac UI 의 Walk Lab 가 Sprint 11 텔레메트리 패널 완성 후
자동화 예정 — 현재는 수기):

| 항목 | 방법 |
|------|------|
| IMU pitch/roll 최대값 | `dxl_monitor` 의 IMU 페이지 또는 SSH 로 `MotionStatus::FB_GYRO` tail |
| 모터 온도 (ID 13, 14, 15, 16) | `dxl_monitor` → control table address 43 |
| 진동 (서브jective) | 짧은 영상 (스마트폰) — 1 page = 1 영상 |
| 자세 복귀 정확도 | 거치 시 페이지 종료 후 평면 접지 / 자세 시각 검사 |

테스트 결과는 `docs/reports/SPRINT_5_WALK_PROGRESSION_REPORT.md` (없으면 생성) 에 페이지별
표로 정리.

## 7. 다음 단계 (페이지 110~115 통과 후)

| 우선순위 | 항목 | reference |
|---------:|------|-----------|
| 1 | walk-engine `slowWalk` 프리셋 (period=600 ms, x_amp=15 mm) 거치 실행 | `docs/walk-lab/V1_DESIGN.md` |
| 2 | NimbRo patch 10 (`AngleEstimator` complementary filter) Rust 포팅 | `docs/walk-lab/COMMUNITY_REFERENCES.md §3-C` |
| 3 | NimbRo patch 12 (`smooth start`, `balance_angle_smooth_gain` LPF) Rust 포팅 | `docs/walk-lab/COMMUNITY_REFERENCES.md §3-A/B` |
| 4 | NimbRo patch 16 (fall protection — IMU 임계값 → page 10/11 자동 호출) Rust 포팅 | `docs/walk-lab/COMMUNITY_REFERENCES.md §3-D` |
| 5 | `normalWalk` (x_amp=25 mm) → `fastWalk` (period=500 ms) | `docs/walk-lab/V1_DESIGN.md` |

**달리기 (`jog`, `running`) 는 페이지 110~115 통과 + walk-engine 4 항목 완료 후, 별도
연구 사이클**로 진행. 현재 자료로는 미완.

## 8. 재생성

페이지 deltas 를 수정하려면:

```sh
# motions/test/walk-progression-v1.json 의 deltas_deg 값 수정 후:
python3 scripts/research/generate_walk_test_motion.py \
  --out motions/test/walk-progression-v1.bin
python3 scripts/research/extract_motion_pages.py \
  motions/test/walk-progression-v1.bin --only-populated | grep '^11[0-5]'
```

스크립트는 `darwinop-ens/Data/motion_4096.bin` 의 page 9 (walkready) 를 매번 새로 읽어
오므로, 우리가 의도하지 않은 drift 없이 항상 verified pose 에서 출발한다.

## 9. 관련 문서

- 모션 포맷: [`docs/motion-format/page-format.md`](../motion-format/page-format.md)
- 외부 모션 라이브러리 reference: [`docs/motion-format/EXTERNAL_MOTION_LIBRARIES.md`](../motion-format/EXTERNAL_MOTION_LIBRARIES.md)
- Walk Lab 8 프리셋 설계: [`V1_DESIGN.md`](V1_DESIGN.md)
- 커뮤니티 walk reference: [`COMMUNITY_REFERENCES.md`](COMMUNITY_REFERENCES.md)
- 하드웨어 검증 프로토콜 (전반): [`docs/HARDWARE_VERIFICATION_PROTOCOL.md`](../HARDWARE_VERIFICATION_PROTOCOL.md)

# Anbernic 게임패드 보행 고도화 설계 — 좌우·회전·복합 블렌딩

> 대상 브랜치/배포: 온보드 walklab-brokerage(C++03, 로봇 g++) — `firmware-patches/walklab-brokerage/`. 엔진(`firmware-backups/.../Walking.cpp`)은 읽기 전용·미수정.
> 원칙: 결론 먼저, 보수적·검증값 우선, 단일 점프 금지, 증거 기반 완료.

## 1. 배경/현황

**결론**: 사용자 3요청(① 좌우 고속·역동화 ② 회전 연속/고속/대각 ③ 복합 보행 유기화)은 모두 *상수 클램프 + L1 거버너 norm + per-axis 독립 슬루*라는 세 레이어 선택의 산물이며, 엔진 자체가 아니라 **brokerage 셰이핑 레이어**에서 푼다.

파이프라인:
```
RG G01 동글(XInput) → GamepadPilot 디코드 → MapGamepad((x mm,y mm,a deg))
 → v1 명령 라인 → WalkLabBrokerage.ApplyCommandLine
 → (1) GovernEnvelope L1 클램프 → (2) SlewToward per-latch 가속 제한
 → (3) GateSchedule boost → walking->X/Y/A_MOVE_AMPLITUDE
 → Walking::Update() = leg IK + gyro balance
```

검증된 엔진 사실(실측):
- `MX28.h:11 //#define MX28_1024` **주석 처리** → `#else` 분기(`*4` gyro)가 컴파일됨(Walking.cpp L588-598). "gyro가 보정 가능" 전제 성립.
- `Y_MOVE_AMPLITUDE/2`(L269), `A_MOVE_AMPLITUDE*PI/180/2`(L284) — 명령이 발 단위로 **반감**.
- `Y_SWAP = Y_SWAP_AMPLITUDE + |Y_MOVE/2|*0.04`(L274) — 0.04 coupling은 무의미(28mm서 +0.56mm). sway는 명시적으로 올려야.
- computeIK 실패 시 `return; // Do not use angle`(L553) — 그 틱 joint-write 폐기 = mid-stride freeze. **하드 천장**.
- `m_yswap_base`는 Run 진입 시 `walking->Y_SWAP_AMPLITUDE`(=config 19)로 덮어씀(WalkLabBrokerage.cpp L1078) → `DEFAULT_Y_SWAP_AMPLITUDE` 상수 상향은 **무효**.
- factory config.ini: y_swap=19, z_move=35, hip_roll=0.6, ankle_roll=1.2, knee=0.2, ankle_pitch=0.6, period=600, dsp=0.1, y_offset=5.

## 2. 요소별 근거

### 2.1 좌우(request #1)
3중 직렬 클램프가 전부 22에 고정: GP_MAX_SIDE_MM(L83)·ENVELOPE_Y_MAX(L71) + 엔진 2× 반감 + SLEW_DY_MAX=6 가속 바닥. 진짜 천장은 IK 도달성(computeIK NaN)이고 자이로 권한은 `*4`로 큼 — 단, brokerage 베이스 게인(0.5/1.0)이 factory(0.6/1.2) **미만**이라 먼저 복원해야 자이로가 넓은 excursion을 커버.

### 2.2 회전(request #2)
두 원인: (a) 끊김 = SLEW_DA_MAX=4/latch 계단 램프(0→12 ~900ms). (b) 안 돎 = GP_MAX_TURN_DEG=12 + 엔진 반감(발 yaw peak 6°). A_MOVE는 발 위치를 안 바꿔(회전성분, L164) IK NaN 거의 무유발 — 18°(peak9°)는 IK·발yaw충돌(~peak20°) 모두 마진 충분. 비유: 회전은 발을 옆으로 밀지 않고 *제자리에서 돌리는* 동작이라 다리 길이 한계와 무관, 두 발이 서로 발끝을 향해 도는 충돌만이 경계.

### 2.3 복합 블렌딩(request #3)
'포기' 느낌의 단일 원인: GovernEnvelope의 L1(택시캡) budget — 3축 동시최대 sum=3.0이 1.15/3=38%로 *세 축 동시* 절단. 추가로 per-axis 독립 슬루가 turn(3 latch)을 stride(5 latch)보다 먼저 도착시켜 의도 외 중간 블렌드 통과. 엔진은 x/y/a를 한 ep[]에 literally SUM(L499-510)하므로 L1 box보다 L2/타원이 feasible set에 부합.

## 3. 리서치 vs 검증 — 불일치와 채택

| 항목 | 리서치 | 검증(safer) | 채택 | 근거 |
|---|---|---|---|---|
| ENVELOPE_SUM_MAX | 1.30 → L2 radius 1.0 | 1.25(L1), L2는 신규상수 0.85 시작 | **1.25 / L2 분리** | 전 클라이언트·Switch 50mm 노출, 같은 상수 재해석 silent 위험 |
| SLEW_DA_MAX | 7.0 | 5~6 시작 | **6.0** | 첫걸음 capturability, 7은 표면별 검증 후 |
| SLEW_DY_MAX | 7.0 | 7.0 | **7.0** | DX=8 미만 유지 |
| 좌우 진폭 | 28→32 | 28만, 32는 스윕 후 | **28(P2)/32(P7)** | 미측정 ceiling 단일 점프 금지 |
| DEFAULT_Y_SWAP→22 | 권고 | REJECT(무효) | **미채택** | L1078서 config 19로 덮어씀 |
| 베이스 게인 | lateral pair만 정합 | lateral 정합 + sagittal 불일치 명시 | **lateral만(P0)+코멘트** | knee/ankle_pitch는 factory 초과 |
| 회전 진폭 | 18→20 | 18, 20은 14 무스컬프 후 | **18(P4)/20(P7)** | 단계 검증 |

## 4. 알고리즘 보완
- **동기화 블렌드 슬루**(P1): N=max(ceil(|Δ|/cap)), 각 축 Δ/N 전진·매 latch 재계산. twist 벡터 직선 이동·peak rate 감소(안정화). 순수함수.
- **결합강도 게이트 스케줄**(P1): intensity = min(1, sqrt(Σ(축/max)²)). 블렌드에 케이던스·발높이 부여.
- **gate-on-y**(P6): GateSchedule ratio = max(|x|/x_max, |y|/ENVELOPE_Y_MAX). 순수 strafe에 Y_SWAP/Z_MOVE boost(IK freeze 지연). 시그니처에 y 추가 → 3파일.
- **L2/타원 엔벨로프**(P7): 신규 ENVELOPE_L2_RADIUS=0.85 시작. 대각 관대·코너 매끄러움.
- **turn-priority a-floor**(P7): 초과 시 a 최대 30%만 축소(총진폭 무증 → freeze 무위험). '전진 중 안 돎'의 안전한 본命 해법.

## 5. 순차 구현 계획

| Phase | 목표 | 출하성 |
|---|---|---|
| 0 | 베이스 lateral 게인 0.6/1.2 정합(무진폭) | 독립 |
| 1 | 동기화 슬루 + 결합강도(구조·무클램프) | 독립 |
| 2 | 좌우 22→28(GP+ENVELOPE 동시) | 독립 |
| 3 | SUM 1.15→1.25(L1) | 독립 |
| 4 | 회전 12→18(GP+ENVELOPE 동시) | 독립 |
| 5 | 슬루 DY 6→7·DA 4→6 | 독립 |
| 6 | gate-on-y(별도 커밋·자체 테스트) | 독립 |
| 7 | (선택) 좌우 32·회전 20·L2·a-floor — 스윕 검증 게이트 | 개별 |

**불변식**: SIDE/TURN은 GP_MAX_*와 ENVELOPE_*_MAX를 항상 동일값으로 같이 변경(작은 쪽 클램프). 각 페이즈는 host 테스트 green 선행 후 온로봇.

## 6. 실기 램프 프로토콜
전제: 스탠드 거치·스포터·배터리 분리 손닿는 곳·**측정 중 Mac 앱 종료**.
- 스텝0(벤치): 전 상수 현행, 정적 3축 풀 명령 단일 스텝, computeIK skip 0 베이스라인.
- 스텝1(P0): lateral 게인만, 측면 탭 push-recovery 진동 부재.
- 스텝2(P1): 동기화 슬루, x/y/a_lat 동일 latch 도착.
- 스텝3(P2): 좌우 28, y_lat 28·freeze 부재, 2m 측보.
- 스텝4(P3): SUM 1.25, crab-호 CoP 발 다각형 내.
- 스텝5(P4): 회전 18, 누적 yaw ~1.5x·scuff 부재.
- 스텝6(P5): 슬루, 매트·타일 각 표면 첫걸음 과회전 부재.
- 스텝7(P6): gate-on-y, (y,z) 코너 스윕 vertical freeze 부재.
- 스텝8(P7): 좌우32(스윕≤0.8×)·회전20(14 무스컬프 후)·L2(전격자 스윕 후 0.85→1.0)·a-floor 개별 게이트.

## 7. 롤백
페이즈별 독립 git revert 또는 상수 단일 되돌림. SIDE/TURN은 짝으로 롤백. 구조 페이즈는 통째 revert. 온로봇 이상 시 ①배터리 분리 ②직전 안정값 ③**재배포+재기동+신선도 확인**(구 바이너리 잔존 함정). 엔진 미수정이라 엔진 롤백 불요. 비상: 전 상수 baseline(22/12/1.15/6/4/0.5/1.0).

## 8. 검증 체크리스트
- [ ] 각 페이즈 host 테스트(test_transport/test_gamepad) green — 로봇 접근 전.
- [ ] GP_MAX_* 와 ENVELOPE_*_MAX 짝 일치(SIDE 28=28, TURN 18=18).
- [ ] Phase 0(게인)이 Phase 2/3(좌우 진폭)보다 선행.
- [ ] DEFAULT_Y_SWAP 상수 미상향(무효 확인).
- [ ] gate-on-y는 별도 커밋·신규 test_gate_schedule_lateral 동반.
- [ ] 32/20/L2는 온스탠드 스윕/무스컬프/전격자 검증 통과 후에만.
- [ ] sagittal 게인(knee/ankle_pitch) 불일치 코멘트 명시(이번 미변경).
- [ ] 온로봇 측정 시 Mac 앱 종료.
- [ ] computeIK freeze(TEL2 phase stall/loop_ms 스파이크) 매 단계 부재 확인.
- [ ] CoP(copx/copy) 발 다각형 내 — 측·복합 단계.

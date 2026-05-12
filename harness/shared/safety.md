# Hardware Safety — DARwIn-OP / OP2 운영 안전

> 사용자가 로봇과 직접 작업하기 전 매번 점검할 항목.
> Sprint 1 부터 forge-cli가 첫 연결 시 이 체크리스트를 출력.

## 매번 (모든 작업 전)

- [ ] **정비 스탠드(cradle)에 거치**. 토크 ON 명령 전 필수.
- [ ] **e-stop 토글 ON-OFF 동작 확인** (모터 전원이 즉시 끊기는지).
- [ ] **LiPo 셀 전압 측정**: 부저식 cell checker로 3 셀 모두 3.7 V 이상 확인. 3.3 V 이하 셀이 있으면 즉시 충전 (방전 중지).
- [ ] **온도**: MX-28 케이스를 손등으로 만져 차가운지 확인. 미지근하면 5분 휴식.
- [ ] **케이블 결속**: 모터 daisy chain 케이블이 빠지거나 헐거운 곳 없는지 시각 점검.
- [ ] **Mac 측 권한**: `ls /dev/cu.usbserial-*` 가 디바이스를 보고하는지.

## 모션 작업 전 (Sprint 3+)

- [ ] **다리 토크 OFF**: `forge torque off --joints leg-l,leg-r`
- [ ] **외부 SMPS 연결**: 배터리 부담 줄이기
- [ ] **첫 자세 = 안전 자세**: walk_ready 자세에서 시작 (어깨 약간 벌리고 무릎 살짝 굽힘)
- [ ] **속도 제한**: 한 관절이라도 4096 step / 100 ms 초과 슬루(slew) 금지

## 워크 엔진 작업 전 (Sprint 5)

- [ ] **배터리 모드** (SMPS 분리): 보행 중 케이블 텐션은 위험
- [ ] **앞뒤 50 cm 빈 공간**: 넘어질 경우 머리 보호
- [ ] **MX-28 케이스 온도 < 40°C** (IR 측정)
- [ ] **첫 명령 = `walk start --x 0 --y 0 --a 0`** (제자리 워킹) → 안정성 5초 확인 → 작은 보폭

## 절대 금지

1. **펌웨어 업로드를 forge가 자동 수행** — 사용자 명시 확인 다이얼로그 없이는 unconditionally 거부.
2. **다리 모터 강제 회전** (사람 손으로 토크 ON 상태 모터를 돌리기) — 기어 박살.
3. **충돌 후 재가동 전 점검 생략** — 호른 기어 균열 시 다음 가동에서 폭발적 파손 가능.
4. **LiPo가 부푼 상태로 사용** — 즉시 LiPo safe bag에 분리 폐기.
5. **2 m 초과 USB 케이블 사용** — 1 Mbps에서 노이즈 한계.
6. **USB hub 경유** — latency 문제, 1 Mbps 통신 비안정.

## 사고 대응

| 상황 | 즉시 조치 |
|------|-----------|
| 모터 stall (찌-소리) | e-stop 토글 OFF |
| 연기·플라스틱 냄새 | e-stop OFF, LiPo 분리, 환기, 30분 관찰 |
| LiPo가 풍선처럼 부풀음 | 손대지 말고 LiPo safe bag으로 운반, 폐기 |
| 로봇 낙하 | torque off → 호른 기어 시각·청각 점검 → 의심 시 모터 교체 |

## 출처

- ROBOTIS DARwIn-OP 매뉴얼
- HobbyKing LiPo safety 가이드
- 우리 [`engineering-foundations.md`](../../docs/harness/engineering-foundations.md)

---

## walk-ready P-gain Ramp (★ Sprint 9-13 신규)

`forge walk-ready` 가 자동 실행하는 4단계 ramp:

| 단계 | P-gain | 시간 (ms) | UI 색상 |
|------|--------|-----------|---------|
| 1 | 0 (free) | 0 | 회색 |
| 2 | 8 (low) | ~750 | 노랑 |
| 3 | 16 (mid) | ~1500 | 주황 |
| 4 | 32 (full) | ~2250 | 녹색 |

> ⚠️ **BLOCKER C3**: `[0, 8, 16, 32]` ramp는 ROBOTIS 원본에 없는 자체 추가.
> `safety::torque_ramp` 의 출처 / 안전 근거 부족 — 실 검증 필요.
> 자세히: `BLOCKERS.md` → `docs/reports/AUDIT_MOTION_WALK_SYNTH.md` C3.

## 모터 온도 임계 (★ 신규)

walk-ready / motion play 후 모터 케이스 온도:

| 온도 | UI 색상 | 자동 액션 |
|------|---------|----------|
| < 40°C | 녹색 | OK |
| 40~55°C | 노랑 | 다음 명령 ~3초 지연 |
| 55~60°C | 주황 | "5분 휴식 후 재시도" 다이얼로그 |
| **≥ 60°C** | **빨강** | **자동 e-stop + LiPo 분리 권고** |

`fc_joint_read_state.present_temperature` 5초 주기로 모든 16 모터 BULK_READ → max.

## HighRisk 모션 confirm_risk=true (★ 신규)

`SafetyClass::HighRisk` 카탈로그 (Hand Standing, Front Roll, Back Roll) 실행 전:

- [ ] 정비 스탠드 거치 (UI 자동 체크 불가 — 사용자 시각 확인)
- [ ] 주변 50 cm 빈 공간
- [ ] `confirm_risk` 체크박스 명시 체크
- [ ] 위 모두 만족 → `forge motion play --slot N --confirm-risk`

UI: `MotionLibraryView` 재생 버튼이 카탈로그의 SafetyClass에 따라 다이얼로그 분기.

→ 자세히: [`../../docs/harness/v2-mac-ui-handoff.md`](../../docs/harness/v2-mac-ui-handoff.md) §3

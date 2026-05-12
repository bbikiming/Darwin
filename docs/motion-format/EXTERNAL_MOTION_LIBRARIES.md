# 외부 모션 라이브러리 — 설계 reference

> 우리 모션 합성 (Sprint 9~13), 페이지 라이브러리 큐레이션, 인터랙티브 시나리오 디자인 시
> 직접 참고할 수 있는 **6 개 외부 `motion_4096.bin` 의 페이지 패턴·이름 관습·체이닝 디자인**
> 을 한곳에 정리.
>
> 원본 파일·SHA-256·라이선스: [`motions/external/MANIFEST.toml`](../../motions/external/MANIFEST.toml)
> Cross-source 페이지 비교 표: [`motions/external/_pages-summary.md`](../../motions/external/_pages-summary.md)
> 페이지 카탈로그 CSV: [`motions/external/_catalog/`](../../motions/external/_catalog/)

## 1. 페이지 슬롯 규약 (커뮤니티 표준)

| 슬롯 | 관습 | 출처 |
|------|------|------|
| **0** | 빈 페이지 (1-step) — 일부 fork 만 사용 | hros5-motion_4096 |
| **1** | `init` — base pose, 거의 모든 인사·댄스 페이지의 복귀 지점 (`next=1` 또는 `exit=1`) | 6 개 모두 |
| **2..6** | `ok / no / hi / ?? / talk1` — 기본 인터랙션 (스톡 ROBOTIS) | 6 개 모두 |
| **9** | `walkready` — 보행 진입 자세 | 6 개 모두 |
| **10, 11** | 낙상 복구 (`f up` / `b up`) | 6 개 모두 |
| **12, 13** | 킥 (`rk` / `lk`) — **좌우 미러 합성의 prior art** | 5 개 (HROS5-live 제외) |
| **15, 16** | `sit down` / `stand up` | 6 개 모두 |
| **17~19** | `mul1` → `mul2` → `mul3` — next-chain 데모 (3-페이지 시퀀스) | 5 개 |
| **23~31, 41~47** | `d1~d4` / `talk2` 변주 — 시연용 (의미 부족, 리네이밍 권장) | 5 개 |
| **54~58** | `int` — 5-페이지 인사 체인 | 5 개 |
| **70, 71** | `rPASS` / `lPASS` — 사커 패스 | 5 개 |
| **75** | (`skate`) — Interbotix 만 추가 | HROS5-src/dest |
| **90, 91** | `lie down` / `lie up` | 5 개 |
| **100~108** | **사용자 슬롯 1 — `personal-assistant` 가 ergonomic 으로 활용** | personal-assistant |
| **150~152** | 사용자 슬롯 1 보조 | personal-assistant |
| **237~241** | `sit down` repeat 변주 (RoboPlus Action 데모) | 5 개 |
| **250~255** | **사용자 슬롯 2 — `personal-assistant` 가 인사 set 으로 활용** | personal-assistant |

### 우리 페이지 슬롯 권고

스톡 (1..91, 237~241) 은 **건드리지 말 것** — 백업이 보존되고 외부 도구와 호환이 유지된다.
새 페이지는 다음 영역에 배치:

| 범위 | 용도 |
|------|------|
| 92..99 | 예약 (보행 변주 — walk-forward, walk-turn 등) |
| 100..149 | **실험 / WIP** — Sprint 9~13 합성 결과 임시 저장 |
| 150..199 | **검증 완료** — 실기체 테스트 통과한 페이지 |
| 200..249 | **프로덕션** — 사용자 노출 라이브러리 |
| 250..255 | **인터랙티브 set** — `personal-assistant` 관습 따라 인사·표정 |

## 2. 페이지 체이닝 패턴

### 2-A. `next` only — 정상 종료 시 다음 페이지

```
17 (mul1, →18) → 18 (mul2, →19) → 19 (mul3, →0) → STOP
```
**용도**: 다단계 시퀀스 (예: 일어서기 1→2→3, 댄스 1→2→3).

### 2-B. `next` 만 = base pose 복귀

```
101 (neck_1, →100) → 100 (base) → STOP
102 (neck_2, →100) → 100 (base) → STOP
```
**용도** (personal-assistant 의 page 101~107): **각 액션이 자기 완결적이고, 항상 base 로
돌아온다**. 호출 측이 임의 시점에 다음 페이지를 트리거할 수 있어 라이브러리화에 적합.

### 2-C. `exit` 만 — Stop() 호출 시 안전 복귀

```
20 (wave, next=1, exit=1) → 1 (init) → STOP
```
**용도** (HROS5 의 page 20, 22, 25, 35, 47, 48): 인터랙티브 페이지 (인사·댄스) 가 사용자
인터럽트로 Stop() 되어도 안전한 자세로 복귀.

### 2-D. `next` + `exit` 분리

```
47 (dance1, next=101, exit=1) → 101 (test2) → 102 (test3, exit=1) → ...
정상: dance 컴비네이션 자동 진행
Stop(): 즉시 page 1 (init) 으로 복귀
```
**용도**: 인터럽트 가능한 긴 시퀀스.

### **우리 합성기 권고**

- 1-페이지 액션: `next=0, exit=walkready_id` 권장.
- 모듈식 라이브러리 페이지: `next=base_id, exit=base_id`.
- 인터랙티브 인사·댄스: `next=다음, exit=1 또는 walkready_id`.
- 보행 진입 페이지 (walkready 등): `next=0, exit=0` (사용자 명시 종료만).

## 3. 페이지 이름 컨벤션

### 좋은 이름 (`motion_dest.bin` 리네이밍 사례)

| 변경 전 | 변경 후 | 패턴 |
|---------|---------|------|
| d3 | scratch_head | 신체 부위 + 행동 |
| d2 / d2 | wave_1a / wave_1b | 접미사 `_<n><a/b>` 로 체인 단계 표시 |

### 나쁜 이름

- `d1, d2, d3, d4` — 의미 없음
- `talk2` (7 페이지) — 어떤 talk2 인지 모호
- `int` (5 페이지) — 약어 + 중복
- `??` — 의도 불분명
- `gomwqf` (personal-assistant page 151) — 오타 추정

### 우리 컨벤션 권고

- 영문 소문자 + underscore: `wave_left`, `neck_stretch_1`, `kick_right_short`
- 길이 13 자 이내 (Action.h MAXNUM_NAME=13)
- 신체 부위 + 행동 + (선택) 변주 번호
- 체인은 `<base>_<n><a/b>` 형식: `dance_1a, dance_1b, dance_2a`

## 4. PAGEHEADER 필드 활용

### `repeat` (헤더 byte 15)

| 값 | 사용 사례 |
|----|-----------|
| 1 | 기본 — 한 번 실행 |
| 3 | personal-assistant page 106 (back_2), 107 (arm_2) — **짧은 반복 운동** |
| 4, 6, 20 | page 237~241 (sit down) — **장시간 동일 동작** (RoboPlus 데모) |

### `schedule` (헤더 byte 16)

| 값 | 의미 | 6 개 .bin 사용 |
|----|------|-------------------|
| 0x00 | SPEED_BASE — STEP 의 time 필드를 무시, speed/accel 로만 진행 | 사용 안 함 |
| **0x0a** | **TIME_BASE** — STEP 의 time/pause 가 정확한 ms | **6 개 모두 100% 사용** |

**우리 JSON 권고**: `play_ms`, `pause_ms` 만 노출. `speed`, `accel` 은 hint 로 라운드트립 보존.

### `speed` (헤더 byte 22)

| 값 | 사용 사례 |
|----|-----------|
| 16 | 슬로우 인사 (page 55~57 int) |
| 21 | 부드러운 시연 (page 23 d1, page 29 talk2 일부) |
| **32** | **기본값 (스톡 95%)** |
| 40, 42, 50, 64 | 빠른 액션 (page 9 walkready 일부, dance, slow-wake) |

### `accel` (헤더 byte 24)

거의 모두 `32` 고정. 일부 페이지만 다름. **우리 합성기는 32 default 권장**.

### `next`, `exit` 사용 빈도

| 필드 | 사용률 | 비고 |
|------|--------|------|
| `next=0` (정지) | ~85% | 1-페이지 자기완결 액션 |
| `next=N` (체인) | ~15% | mul1→2→3, talk2 7-체인, personal-assistant 101~107→100 |
| `exit=0` (없음) | ~95% | 스톡은 거의 사용 안 함 |
| `exit=1 또는 N` | ~5% | HROS5 인터랙티브 페이지만 활용 |

→ **`exit` 활용은 우리가 디자인적으로 적극 도입할 차별점**.

## 5. STEP 활용 패턴

| `stepnum` | 페이지 수 (6 개 .bin 합산) | 용도 |
|-----------|---------------------------:|------|
| 1 | ~30 | 단일 포즈 (walkready, sit down, stand up, init) |
| 2 | ~15 | 진입/종료 페어 |
| 3 | ~15 | 짧은 액션 |
| 4 | ~25 | 표준 시연 (talk2, d1, neck_1) |
| 5 | ~50 | **가장 많이 사용 — talk2 변주, ok, no, hi** |
| 6 | ~30 | 복합 액션 (back_1, lie down, d3) |
| 7 | ~25 | **최대 — 풀 시퀀스 (rk, lk, mul1, mul2, talk2)** |

→ **MAXNUM_STEP=7 의 한계**가 모션 표현력의 사실상 상한. 7-step 으로 부족하면 next-chain.

## 6. 우리 모션 합성기 (`forge-cli synth`) 설계 함의

### `synth mirror <page>` (Sprint 9~13)

좌우 미러는 `darwinop-ens/Data/motion_4096.bin` 의 page 12 (rk) ↔ page 13 (lk) 가 검증 reference.
NimbRo `patches-optional/0024-ActionEditor-added-fuction-to-apply-mirrored-pages.patch` 의
clean-room 인용:
- 미러 대상 관절: `R_*` ↔ `L_*` 짝 교환
- 좌우 대칭 관절 (HEAD_PAN, HEAD_TILT): 부호 반전
- 페이지 헤더의 `name` 도 `_r → _l` 또는 `right → left` 자동 치환

### `synth sequence <id1> <id2> <id3>` (Sprint 12~13)

`darwinop-ens` page 17→18→19 (mul1→2→3) 가 prior art. 자동 생성 시:
- 입력 페이지의 마지막 step pose ≈ 출력 페이지의 첫 step pose (보간 부드러움 검증)
- `next` 자동 chaining
- 마지막 페이지의 `next=0`

### `synth validate <file>` 4-stage validator (Sprint 12)

- Stage 1 — 페이지 헤더 무결성: name 길이, schedule=0x0a, stepnum 1..7, checksum.
- Stage 2 — STEP pose 범위: 각 관절 INVALID_BIT_MASK(0x4000) / TORQUE_OFF_BIT_MASK(0x2000)
  외 4096-tick 범위.
- Stage 3 — IK 안정성: 각 step 의 발바닥 평면 (3D Kinematics) — `--single-foot-ok` 옵션
  허용 (kick 페이지).
- Stage 4 — 체인 일관성: `next` / `exit` 가 가리키는 페이지 존재성.

### `motions/external/_catalog/*.csv` 활용

`forge-cli synth library list` 가 우리 라이브러리만이 아니라 외부 6 개를 cross-reference
표시 가능 — 사용자가 "비슷한 페이지 이미 있는지" 확인.

## 7. 인용 시 라이선스 요약

| 페이지 출처 | 우리 라이브러리에 페이지 데이터 직접 임포트 |
|-------------|--------------------------------------------|
| `darwinop-ens` (스톡 ROBOTIS) | ✅ Apache 2.0 — 출처 보존 |
| `nimbro-op` (소프트웨어) | ✅ BSD-3 — LICENSE 텍스트 동봉 |
| `personal-assistant` | ⚠ license=TODO — **페이지 메타 (사실) 인용만, 바이너리 임포트 보류** |
| HROS5 (GPL) | ❌ 바이너리 임포트 금지 — 페이지 헤더 메타데이터만 사실 인용 |

자세히 → [`vendor/LICENSES.md`](../../vendor/LICENSES.md).

## 8. 참고 문서

- 페이지/스텝 메모리 포맷: [`docs/motion-format/page-format.md`](page-format.md)
- 페이지 카탈로그 (`motion4096.bin` per-page TOML): [`docs/motion-format/page-metadata-motion4096.toml`](page-metadata-motion4096.toml)
- 모션 합성 PRD: [`docs/prd/motion-synthesis-v1.md`](../prd/motion-synthesis-v1.md)
- 외부 모션 카탈로그 매니페스트: [`motions/external/MANIFEST.toml`](../../motions/external/MANIFEST.toml)
- 외부 모션 cross-source 비교: [`motions/external/_pages-summary.md`](../../motions/external/_pages-summary.md)
- 커뮤니티 자료 카탈로그: [`research/community/INDEX.md`](../../research/community/INDEX.md)
- 보행 reference: [`docs/walk-lab/COMMUNITY_REFERENCES.md`](../walk-lab/COMMUNITY_REFERENCES.md)

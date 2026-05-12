# motions/external/_pages-summary.md

> 6 개 외부 `.bin` 의 페이지 번호별 cross-source 비교. **빈 칸은 페이지 미사용(빈 페이지)**.
> 같은 번호에 같은 이름이 들어가면 "스톡 ROBOTIS 카탈로그를 보존" 한 것이고, 이름이 다르면
> 그 저장소가 의도적으로 재할당한 것.
>
> 갱신: 2026-05-12. 재생성: `scripts/research/extract_motion_pages.py` 실행 후 수기로 정리.

## 페이지 1..50 (인터랙션 + 기본 보행)

| #  | darwinop-ens | nimbro-op | op2-personal-assist | hros5-motion_src | hros5-motion_dest | hros5-motion_4096 | 비고 |
|---:|--------------|-----------|---------------------|------------------|-------------------|-------------------|------|
| 0  | —            | —         | —                   | —                | —                 | (empty, 1 step)   | hros5 만 page 0 사용 |
| 1  | init         | init      | init                | init             | int               | init              | dest 의 "int" 는 단순 글자 잘림 변환 |
| 2  | ok           | ok        | ok                  | ok               | ok                | —                 | |
| 3  | no           | no        | no                  | no               | no                | —                 | |
| 4  | hi           | hi        | hi                  | hi               | hi                | —                 | |
| 5  | ??           | ??        | ??                  | ??               | ??                | —                 | |
| 6  | talk1        | talk1     | talk1               | talk1            | talk1             | —                 | |
| 8  | —            | —         | —                   | —                | —                 | slow-wake (→1)    | hros5 진입 시퀀스 |
| 9  | **walkready (1 step)** | **walkready (3 step)** | walkready (1 step) | walkready | walkready | walkready | **nimbro 는 3-step 으로 확장** |
| 10 | f up         | up f      | f up                | f up             | f up              | —                 | nimbro 는 이름 표기 차이 |
| 11 | b up         | up b      | b up                | b up             | b up              | —                 | nimbro 는 이름 표기 차이 |
| 12 | rk           | rk        | rk                  | rk               | rk                | —                 | right kick (모션 합성 좌우 미러 기준) |
| 13 | lk           | lk        | lk                  | lk               | lk                | —                 | left kick |
| 15 | sit down     | sit down  | sit down            | sit down         | sit down          | sit down          | |
| 16 | stand up     | stand up  | stand up            | stand up         | stand up          | —                 | |
| 17 | mul1 (→18)   | mul1 (→18)| mul1 (→18)          | mul1 (→18)       | mul1 (→18)        | —                 | 체이닝 시작 |
| 18 | mul2 (→19)   | mul2 (→19)| mul2 (→19)          | mul2 (→19)       | mul2 (→19)        | —                 | |
| 19 | mul3         | mul3      | mul3                | mul3             | mul3              | —                 | |
| 20 | —            | —         | —                   | —                | —                 | wave (→1, exit=1) | hros5 인사 |
| 22 | —            | —         | —                   | —                | —                 | arms up (→1)      | |
| 23 | d1           | d1        | d1                  | d1               | d1                | —                 | |
| 24 | d2 (→25)     | d2 (→25)  | d2 (→25)            | d2 (→25)         | d2 (→25)          | —                 | |
| 25 | d2           | d2        | d2                  | d2               | d2                | scratch (→1)      | hros5 는 page 25 재할당 |
| 27 | d3           | d3        | d3                  | d3               | **scratch_head**  | —                 | dest 만 의미 부여 |
| 29 | talk2 (→30)  | talk2 (→30)| talk2 (→30)        | talk2 (→30)      | talk2 (→30)       | —                 | |
| 30 | talk2        | talk2     | talk2               | talk2            | talk2             | bow (→1)          | |
| 31 | d4           | d4        | d4                  | d4               | d4                | —                 | |
| 35 | —            | —         | —                   | —                | —                 | excite (→1, exit=1) | |
| 38 | d2 (→39)     | d2 (→39)  | d2 (→39)            | d2 (→39)         | **wave_1a (→39)** | —                 | dest 는 의미화 |
| 39 | d2           | d2        | d2                  | d2               | **wave_1b**       | —                 | |
| 40 | —            | —         | —                   | —                | —                 | talking (→1)      | |
| 41 | talk2 (→42)  | talk2 (→42)| talk2 (→42)        | talk2 (→42)      | talk2 (→42)       | —                 | talk2 체인 시작 |
| 42 | talk2 (→43)  | talk2 (→43)| talk2 (→43)        | talk2 (→43)      | talk2 (→43)       | —                 | |
| 43 | talk2 (→44)  | talk2 (→44)| talk2 (→44)        | talk2 (→44)      | talk2 (→44)       | —                 | |
| 44 | talk2 (→45)  | talk2 (→45)| talk2 (→45)        | talk2 (→45)      | talk2 (→45)       | —                 | |
| 45 | talk2 (→46)  | talk2 (→46)| talk2 (→46)        | talk2 (→46)      | talk2 (→46)       | thanks (→1)       | |
| 46 | talk2 (→47)  | talk2 (→47)| talk2 (→47)        | talk2 (→47)      | talk2 (→47)       | pose (→1)         | |
| 47 | talk2        | talk2     | talk2               | talk2            | talk2             | dance1 (→101, exit=1) | hros5 의 댄스 체인 |
| 48 | —            | —         | —                   | —                | —                 | dance (→51, exit=1) | |

## 페이지 51..255

| #   | darwinop-ens | nimbro-op | op2-personal-assist | hros5-motion_src | hros5-motion_dest | hros5-motion_4096 | 비고 |
|----:|--------------|-----------|---------------------|------------------|-------------------|-------------------|------|
| 51  | —            | —         | —                   | —                | —                 | (→1)              | dance 체인 끝 |
| 54  | int (→55)    | int (→55) | int (→55)           | int (→55)        | int (→55)         | —                 | |
| 55  | int (→56)    | int (→56) | int (→56)           | int (→56)        | int (→56)         | long pose (→1)    | |
| 56  | int (→58)    | int (→58) | int (→58)           | int (→58)        | int (→58)         | —                 | |
| 57  | int (→58)    | int (→58) | int (→58)           | int (→58)        | int (→58)         | —                 | |
| 58  | int          | int       | int                 | int              | int               | —                 | |
| 70  | rPASS        | rPASS     | rPASS               | rPASS            | rPASS             | —                 | right pass |
| 71  | lPASS        | lPASS     | lPASS               | lPASS            | lPASS             | —                 | left pass |
| 75  | —            | —         | —                   | **skate**        | **skate**         | —                 | hros5 src/dest 만 추가 |
| 90  | lie down     | lie down  | lie down            | lie down         | lie down          | —                 | |
| 91  | lie up       | lie up    | lie up              | lie up           | lie up            | —                 | |
| 100 | —            | —         | **robot_initial_**  | —                | —                 | test1 (→101)      | |
| 101 | —            | —         | **neck_1 (→100)**   | —                | —                 | test2             | personal-assist: 거북목 케어 |
| 102 | —            | —         | **neck_2 (→100)**   | —                | —                 | test3 (exit=1)    | |
| 103 | —            | —         | **arm_1 (→100)**    | —                | —                 | —                 | |
| 104 | —            | —         | **back_1 (→100)**   | —                | —                 | —                 | |
| 105 | —            | —         | **leg_1 (→100)**    | —                | —                 | —                 | |
| 106 | —            | —         | **back_2 (rep×3 →100)** | —            | —                 | —                 | |
| 107 | —            | —         | **arm_2 (rep×3 →100)**  | —            | —                 | —                 | |
| 108 | —            | —         | **sit_down**        | —                | —                 | —                 | |
| 150 | —            | —         | sit down            | —                | —                 | —                 | |
| 151 | —            | —         | gomwqf              | —                | —                 | —                 | (오타 추정) |
| 152 | —            | —         | robot_initial_      | —                | —                 | —                 | |
| 237 | sit down (rep×6) | sit down (rep×6) | sit down (rep×6) | sit down (rep×6) | sit down (rep×6) | —              | RoboPlus Action 예제 (스톡) |
| 239 | sit down (rep×4 →240) | … | … | … | … | — | |
| 240 | sit down (rep×4 →241) | … | … | … | … | — | |
| 241 | sit down (rep×20) | … | … | … | … | — | |
| 250 | —            | —         | **init_pose**       | —                | —                 | —                 | personal-assist 인사 베이스 |
| 251 | —            | —         | **welcome (→250)**  | —                | —                 | —                 | |
| 252 | —            | —         | **ok (→250)**       | —                | —                 | —                 | |
| 253 | —            | —         | **bye (→250)**      | —                | —                 | —                 | |
| 254 | —            | —         | **Go (→250)**       | —                | —                 | —                 | |
| 255 | —            | —         | **test (→250)**     | —                | —                 | —                 | |

## 관찰

1. **스톡 베이스라인** — `darwinop-ens` ≈ `nimbro-op` ≈ `op2-personal-assistant` 의 page 1..91
   범위는 거의 동일. ROBOTIS 가 OP1 출하 이후 카탈로그를 거의 갱신하지 않았음을 의미.

2. **확장 영역** — page 100~108, 150~152, 250~255 가 커뮤니티가 자유롭게 추가하는
   "사용자 슬롯". 우리 라이브러리도 같은 관습을 따르면 다른 reference 와 충돌이 없다.

3. **`next` 체이닝** — page 17→18→19 (mul1→2→3), 29→30 (talk2), 38→39 (d2),
   41→42→43→44→45→46→47 (talk2 7-page 체인) 가 스톡 패턴.
   `personal-assist` 의 101~107 (모두 `next=100` 으로 base pose 복귀) 는 **모듈식 라이브러리
   설계의 사실상 표준** — 우리 합성기도 동일하게 적용.

4. **`exit` 활용** — hros5 의 wave/scratch/excite/dance 만 `exit=1` 을 지정해
   "Stop() 시 page 1 (init) 로 복귀" 를 명시. 스톡은 거의 사용하지 않음. **인터랙티브
   시나리오 (인사·댄스) 는 exit=1 또는 exit=walkready 가 권장 패턴**.

5. **`schedule=0x0a` (TIME_BASE) 일관성** — 6 개 모두 모든 페이지에서 시간 기반. SPEED_BASE
   는 사실상 사용 안 함. 우리 JSON 포맷도 `play_ms` 만 노출하고 speed 필드는 hint 로.

6. **`skate` (page 75)** — HROS5 가 추가했고 hros5-motion_4096 (라이브) 에서는 또 빠진 것을 보면,
   "실험 단계에서 추가했다가 라이브에서 제거" 사례. **모션 라이브러리에 실험용 페이지 슬롯을
   따로 두는 것** 이 유용함을 시사 (e.g. 110~149 = 실험, 150~199 = 검증, 200~255 = 프로덕션).

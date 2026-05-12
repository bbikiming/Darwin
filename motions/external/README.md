# motions/external/

> 외부 커뮤니티 ROBOTIS OP / OP2 / 파생 플랫폼의 `motion_4096.bin` (및 보조 `.bin`)
> 카탈로그. **원본 파일은 `research/community/` 하위 클론에 보존**하고, 여기서는
> 매니페스트 + 페이지 헤더 추출 CSV + 비교 분석만 둔다.
>
> 우리 모션 합성 (Sprint 9~13) · walking 튜닝 (Sprint 5) · 페이지 라이브러리 큐레이션의
> 직접적인 1차 reference.

## 파일

| 파일 | 내용 |
|------|------|
| `MANIFEST.toml` | 6 개 .bin 의 SHA-256, 출처, 라이선스, 하이라이트 페이지 |
| `_catalog/<id>.csv` | 각 .bin 의 populated 페이지 헤더 (name, repeat, schedule, stepnum, speed, accel, next, exit) |
| `_pages-summary.md` | 6 개 .bin 의 cross-source 페이지 비교 표 |

## 6 개 .bin 요약

| ID                          | 출처                                          | 라이선스        | 명명 페이지 | 핵심 활용 |
|-----------------------------|-----------------------------------------------|-----------------|------------:|-----------|
| `op2-personal-assistant`    | `PersonalAssistantGradProject/...op2`         | TODO (보류)     | **63**      | OP2 실기체. 책상 통증 케어 (page 100~108) + 인사 (page 250~255) **고유 페이지가 가장 많음** |
| `nimbro-op`                 | `NimbRo/nimbro-op`                            | BSD-3 (SW)      | 45          | walkready 3-step 확장 + 낙상 복구. 보행 패치 16 개 (essential) + 9 개 (optional) |
| `darwinop-ens`              | `darwinop-ens/darwin-op`                      | Apache 2.0      | 45          | **OP1 정본 reference**. 스톡 ROBOTIS 카탈로그 그대로 |
| `hros5-motion_4096`         | `Interbotix/HROS5-Framework`                  | **GPL v3 (격리)** | 20          | HR-OS5 라이브 (wave/scratch/bow/dance) — 페이지 의미화 패턴 참고 |
| `hros5-motion_src`          | `Interbotix/HROS5-Framework`                  | **GPL v3 (격리)** | 46          | rme 변환 입력 — 스톡 + skate |
| `hros5-motion_dest`         | `Interbotix/HROS5-Framework`                  | **GPL v3 (격리)** | 46          | rme 변환 출력 — d3/d2 등 무명 페이지에 의미 부여 |

> **합계 6 × 131 072 byte = 786 432 byte ≈ 768 KiB** (256 페이지 × 512 byte 구조).

## 파일 포맷 빠른 참조 (`Framework/include/Action.h`)

```
PAGE = 512 byte
  PAGEHEADER  (64 byte)
    [0..13]   name (ASCII, NUL-padded, MAX 13)
    [15]      repeat            (페이지 반복 횟수)
    [16]      schedule          (0x00 = SPEED_BASE / 0x0a = TIME_BASE)
    [20]      stepnum           (1..7)
    [22]      speed             (글로벌 속도)
    [24]      accel             (가감속)
    [25]      next              (자연 종료 시 이어질 페이지, 0 = 정지)
    [26]      exit              (Stop() 호출 시 이어질 페이지, 0 = 없음)
    [31]      checksum
    [32..62]  slope[31]         (CW/CCW compliance — 최신 MX-28 펌웨어에서 미사용)
  STEP × 7   (각 64 byte)
    [0..61]   position[31]      (uint16 LE, MX-28 goal_position 0..4095)
    [62]      pause             (다음 step 까지 대기, 8 ms 단위)
    [63]      time              (이 step 의 동작 시간, 8 ms 단위)
```

> 31-slot 의 position 배열 — 실제 사용은 ID 1..20 인덱스. INVALID_BIT_MASK (0x4000) /
> TORQUE_OFF_BIT_MASK (0x2000) 로 슬롯 무효화 가능.

## 페이지 추출 (재생성)

```sh
python3 scripts/research/extract_motion_pages.py \
  research/community/darwinop-ens-darwin-op/Data/motion_4096.bin \
  --csv motions/external/_catalog/darwinop-ens.csv \
  --only-populated
```

전체 재생성 — `MANIFEST.toml` 의 `[[motion]]` 블록을 따라 한 번씩 실행.

## 사용 가이드

1. **새 페이지 합성 (Sprint 9~13)** — `darwinop-ens` 의 page 12 (rk) / page 13 (lk) 를
   `forge-cli synth mirror` 의 reference 로 사용. 좌우 미러 검증.
2. **walking 튜닝 (Sprint 5)** — `nimbro-op/software/patches-essential/0012-Walking-tuned-for-NimbRo-OP.patch`
   의 PERIOD_TIME, *_AMPLITUDE, balance gain 값을 읽고 **TeenSize 보정을 제거** 한 형태로 도입.
3. **소셜 모션 디자인** — `hros5-motion_4096` 의 wave / bow / scratch / dance 페이지 구성과
   `hros5-motion_dest` 의 의미화 리네이밍을 보고, 우리 라이브러리의 page-name convention 결정.
4. **인터랙티브 라이브러리 (OP2)** — `op2-personal-assistant` 의 page 100~108 (목/허리 스트레칭)
   + 250~255 (인사) 가 책상 ergonomic 시나리오에 그대로 적용 가능 — **단 실기체 테스트 전 백업
   필수** (`docs/HARDWARE_VERIFICATION_PROTOCOL.md`).
5. **모션 합성 vs 직접 캡처 의사결정** — 6 개 .bin 의 `named_pages` 분포 (45, 45, 20, 46, 46, 63)
   는 "스톡 + 10 개 내외 커스텀" 이 커뮤니티 표준임을 시사. 우리 라이브러리도 비슷한 규모로 유지.

## 안전

`docs/HARDWARE_VERIFICATION_PROTOCOL.md` 절차 준수.

```sh
# 실기 적용 전 항상 백업
cp /darwin/Data/motion_4096.bin /darwin/Data/motion_4096.bin.bak.$(date +%Y%m%d-%H%M%S)
```

페이지 단위 교체 권장. 전체 덮어쓰기 금지. **HROS5 의 .bin 은 GPL — 실기체 적용도
GPL 의무 검토 후에만**.

## 출처 라이선스 요약

| 출처 | 라이선스 | 우리 코어가 임포트해도 되는가 |
|------|----------|------------------------------|
| robot_personal_assistant_op2 | package.xml: TODO (실질 미선언) | **❓ — 코드 임포트 보류**, 문서·페이지 메타 인용 OK |
| nimbro-op (software) | BSD-3-Clause | ✅ (저작권 표기 보존) |
| nimbro-op (hardware/CAD) | CC BY-NC-SA 3.0 | ⚠️ 비상업, ShareAlike — 우리 코어에 포함하지 않음 |
| darwinop-ens/darwin-op | Apache 2.0 | ✅ |
| Interbotix/HROS5-Framework | GPL v3 | **❌ 격리** (`vendor/LICENSES.md` GPL 격리 규칙 참고) |

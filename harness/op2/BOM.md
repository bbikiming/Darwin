# BOM — ROBOTIS-OP2 2세대 (CM-740) 외부 하네스

> OP1과 거의 동일. 차이가 있는 부품만 별도 표시.

## OP1 BOM과 동일

[`../op1/BOM.md`](../op1/BOM.md)의 #1 ~ #15 모두 그대로 적용. 추가/대체 항목만 아래 정리.

## OP2 전용 추가/대체

| # | 부품 | Mfg P/N | 수량 | 단가 (USD) | 구매처 | 비고 |
|---|------|---------|------|-----------|--------|------|
| 16 | mini-HDMI → HDMI 어댑터 케이블, 1 m | UGREEN 11167 | 1 | 9 | Amazon | OP2 비디오 출력 (디버그·시연 시 외부 모니터) |
| 17 | mSATA → USB 3.0 외장 변환 어댑터 | StarTech SATMSATU3 | 1 | 25 | DigiKey | OP2 mSATA SSD 백업·교체 시 |
| 18 | mSATA SSD 64 GB (교체용) | KingSpec MT-064 | 1 | 22 | Amazon | 원본 SSD 노화 대비 spare |

## OP2 특유 주의

- **3.5 mm 오디오 잭 부재**: OP1에서 mic-in 외부 측정을 했다면 OP2에서는 SBC 측 USB 사운드카드로 대체.
- **HDMI 부팅 디스플레이**: 공장 OS 로그를 직접 보고 싶을 때 mini-HDMI에 모니터 연결.
- **mSATA SSD wear**: 장기 사용 OP2는 SSD 수명이 한계에 가까움. Sprint 4에서 forge-cli `health storage` 명령으로 SMART 모니터링.

## 합계 (OP2 추가)

| 카테고리 | USD |
|----------|-----|
| OP1 BOM | 584 |
| OP2 추가 | 56 |
| **OP2 합계** | **~640** |

## 출처

- 동일 `harness/op1/BOM.md`
- ROBOTIS-OP-Series-Data: OP2 specific section

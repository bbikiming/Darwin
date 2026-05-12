# R+ Motion / R+ Task — 모바일 후속

## 한 줄 소개

ROBOTIS의 iOS/Android 모바일 앱. RoboPlus 데스크톱의 가벼운 후속.
ROBOTIS의 신규 모터(특히 학습용 키트 — Smart, Mini)에 초점.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 플랫폼 | iOS / Android |
| 라이선스 | 독점 (무료) |
| 통신 | USB OTG → Bluetooth (BT-410, BT-510) |
| 호환 | DARWIN-MINI, ROBOTIS Mini, OP3 일부 |

## UI 특징

### R+ Motion (모션)
- 터치 기반 step grid
- 한 화면에 16~31관절 슬라이더
- 스와이프로 page 이동

### R+ Task (행동 프로그래밍)
- 블록 코딩 (Scratch 유사)
- 조건/반복/모션 호출
- 태블릿에서 손가락으로 블록 드래그

## DarwinForge 적용

★ — DarwinForge가 macOS 데스크톱 앱이라 모바일 UX는 직접 차용 X. 그러나
다음 패턴은 의미 있음:

1. **Mac 트랙패드 제스처** — 두 손가락 핀치로 timeline zoom, 스와이프로
   step 이동.
2. **블록 코딩 → 자연어** — DarwinForge는 블록 코딩을 자연어로 대체. 이미
   채용. R+ Task의 블록을 보고 "이런 사고 흐름"을 자연어로 어떻게 인식할지
   참고.

## 출처

- R+ Motion (App Store): 검색 "R+ Motion ROBOTIS"
- R+ Task (App Store): 검색 "R+ Task ROBOTIS"
- ROBOTIS-MINI 문서: https://emanual.robotis.com/docs/en/edu/mini/

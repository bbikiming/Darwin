# docs/motion-format/

RoboPlus Action `.mtn` / Page / Step 포맷 분석. `app/core::motion`이 구현할 파서·라이터의 기준.

## 문서

- (Phase 2) `mtn-format.md` — `.mtn` 파일 구조 (페이지·스텝·관절 각도·시간 단위)
- (Phase 2) `page-format.md` — Page/Step 메모리 구조, OP1/OP2 호환성

## 핵심 개념

- **Page** — 하나의 모션 단위. 최대 7개의 Step.
- **Step** — 키프레임. 20개 관절의 각도 + 시간(시작 지연·동작 시간).
- **Pose** — 한 시점의 관절 각도 스냅샷.

## 인용 출처 (Phase 2에서 채워짐)

- ROBOTIS Framework `Framework/src/motion/Action.cpp` (오리지널 파서 구현)
- RoboPlus Action 매뉴얼
- 커뮤니티 분석 문서 (UPenn, Hambot 등)

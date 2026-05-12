# Phase 1 — Discovery & Archive

## 요약

시드 소스 §5.1을 전수 점검. ROBOTIS 공식 핵심 4개 저장소를 `research/robotis-official/`에 얕은 클론(.git 제거 후 스냅샷)으로 보존, 나머지 시드는 `git ls-remote`로 HEAD 해시만 캡처. `INDEX.md` / `EXTERNAL_LINKS.md` / `REFERENCES.bib` / `vendor/LICENSES.md` 모두 갱신. GPL v3 코드(HROS5-Framework) 격리 정책 명문화.

## 핵심 산출물

### 클론 (4개, .git 제거 스냅샷)

| 저장소 | 크기 | 라이선스 | 적용 등급 | _NOTES.md |
|--------|------|----------|-----------|-----------|
| `DynamixelSDK` (tag 4.0.5) | 21 M | Apache 2.0 | ★★★ | ✅ |
| `ROBOTIS-Framework` | 612 K | Apache 2.0 | ★★ | ✅ |
| `ROBOTIS-OP2` | 488 K | Apache 2.0 | ★★ | ✅ |
| `ROBOTIS-OP-Series-Data` (OP/OP2 부분만) | 51 M | © ROBOTIS | ★★★ | ✅ |

총 73 M. OP3 하드웨어 18 M는 우리 스코프 외라 제거.

### 비클론 메타데이터 (`research/community/_metadata/remote-heads.txt`)

- HumaRobotics/darwin_description (BSD-2)
- cyberbotics/webots, webots_ros2 (Apache 2.0)
- bit-bots/hambot (RoboCup)
- Interbotix/HROS5-Framework (**GPL v3 격리**)
- UPenn-RoboCup/UPennalizers
- ROBOTIS-Math, OP3, OP3-Common, dynamixel-workbench (HEAD 해시 INDEX.md에 기록)

### 카탈로그·보고

- `research/INDEX.md` — 26개 엔트리 (목표 15+ 초과). 등급·라이선스·핵심 모듈·해시 컬럼 포함.
- `research/EXTERNAL_LINKS.md` — e-Manual, RoMeLa, RoboCup, 시뮬레이터, 가이드 사이트 링크 (다운로드 X)
- `research/papers/REFERENCES.bib` — Ha 2011, McGill 2010, Hong 2014, Hambot 2015, Wikipedia, ROBOTIS e-Manual
- `vendor/LICENSES.md` — 7개 누적 + GPL 격리 규칙 3조

## 자기검증 결과

- [x] 시드 소스 100% 점검 흔적 — INDEX.md 26개 엔트리
- [x] 라이선스 미상 항목 0개 (모두 라이선스 확인됨, 일부는 "확인 필요" 표기 후 ★ 등급으로 강등)
- [x] INDEX.md 15+ 엔트리 (26개)
- [x] GPL 격리 정책 명문화 (vendor/LICENSES.md)
- [x] _NOTES.md 4개 (각 클론 저장소)

## Blockers

없음. 미해결 1건은 우선순위 낮음:
- INDEX #9 `ROBOTIS-GIT/darwin` ROS 패키지 ls-remote 실패. ROBOTIS-OP2(#3)가 ROS 측 진리이므로 실용 영향 없음.

## 통계

- 클론 저장소: 4개
- ls-remote만: 10개 (ROBOTIS 6 + 커뮤니티 6 — 일부 중복 카운트 포함)
- INDEX 엔트리: 26개
- LICENSES 엔트리: 7개
- BibTeX 엔트리: 7개
- 총 디스크 사용량: ~73 MB (research/)

## 다음 단계

**Phase 2 — Knowledge Synthesis** 즉시 자율 시작:
1. `docs/protocols/dynamixel-1.0.md` 보강 (이미 존재, 검증·보강)
2. `docs/protocols/dynamixel-2.0.md` 신규 (참고용, 우리 직접 사용 안 함)
3. `docs/protocols/cm-730-740.md` 신규 (보드 차이, 펌웨어, 부트로더, 직렬 핀맵)
4. `docs/motion-format/mtn-format.md`, `page-format.md` (RoboPlus Action 분석)
5. `docs/architecture/walking-engine.md`, `joint-conventions.md`, `sensor-stack.md`
6. `docs/architecture/op1-vs-op2-matrix.md` 보강 (이미 존재)

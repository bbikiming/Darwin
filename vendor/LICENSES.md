# vendor/LICENSES.md

> 외부에서 가져온 코드·리소스의 라이선스를 누적 기록. 매 임포트마다 추가.
> 비호환 발견 시 (예: GPL ↔ Apache 2.0 코어 결합) 즉시 격리하고 `BLOCKERS.md`에 기재.
>
> 최종 갱신: 2026-05-09 (Phase 1)

## 우리 프로젝트 라이선스

**Apache 2.0** (사용자 결정, 2026-05-09).

## 호환성 매트릭스

| 우리 코어가 직접 임포트해도 되는가? | Apache 2.0 | MIT | BSD-2/3 | LGPL | **GPL** | 독점 |
|--------------------------------------|:----------:|:---:|:-------:|:----:|:-------:|:----:|
| 라이브러리 정적 링크                 | ✅          | ✅   | ✅       | ⚠️    | ❌       | 사례별 |
| 코드 부분 인용 (재구현 참고)         | ✅          | ✅   | ✅       | ✅    | ⚠️       | ❌    |
| 텍스트·문서 인용                     | ✅          | ✅   | ✅       | ✅    | ✅       | 출처 명시 |

⚠️ = 동적 링크/별도 프로세스 분리 등 조건부 가능. 케이스마다 확인.

## 누적 인덱스

| # | 출처 | 라이선스 | 사용 위치 | 호환성 | 비고 |
|---|------|----------|-----------|--------|------|
| 1 | [ROBOTIS-GIT/DynamixelSDK](https://github.com/ROBOTIS-GIT/DynamixelSDK) | Apache 2.0 | `research/robotis-official/DynamixelSDK/` | ✅ | tag 4.0.5 (`2ded684`). Sprint 1 Rust 포팅의 1차 참조. **코드 직접 임포트 안 함**. |
| 2 | [ROBOTIS-GIT/ROBOTIS-Framework](https://github.com/ROBOTIS-GIT/ROBOTIS-Framework) | Apache 2.0 | `research/robotis-official/ROBOTIS-Framework/` | ✅ | 알고리즘 참조 |
| 3 | [ROBOTIS-GIT/ROBOTIS-OP2](https://github.com/ROBOTIS-GIT/ROBOTIS-OP2) | Apache 2.0 | `research/robotis-official/ROBOTIS-OP2/` | ✅ | Sprint 5 walk engine 1차 참조 |
| 4 | [ROBOTIS-GIT/ROBOTIS-OP-Series-Data](https://github.com/ROBOTIS-GIT/ROBOTIS-OP-Series-Data) | © ROBOTIS, 비상업·인용 | `research/robotis-official/ROBOTIS-OP-Series-Data/` (OP/OP2 부분만) | ✅ (인용) | Phase 2/3 출처. PDF 스니펫 인용 시 출처 명시. |
| 5 | [Interbotix/HROS5-Framework](https://github.com/Interbotix/HROS5-Framework) | **GPL v3** | (클론하지 않음 — 메타데이터만) | **❌ (격리)** | 알고리즘 참고만, 코드 복사 금지. |
| 6 | [HumaRobotics/darwin_description](https://github.com/HumaRobotics/darwin_description) | BSD-2-Clause | (메타데이터만) | ✅ | Sprint 4+ 3D pose에서 URDF 가져올 시 BSD 표기 추가 |
| 7 | [cyberbotics/webots](https://github.com/cyberbotics/webots) | Apache 2.0 | (메타데이터만) | ✅ | 시뮬레이터, 우리 코드와 분리 실행 |
| 8 | [ROBOTIS-GIT/ROBOTIS-OP2-Common](https://github.com/ROBOTIS-GIT/ROBOTIS-OP2-Common) | Apache 2.0 | `vendor/robotis-op2-common/` (21개 STL mesh + URDF xacro + LICENSE 원본 보존) | ✅ | Sprint 7 — SwiftUI 3D 시각화에 사용. URDF의 joint origin/axis를 코드로 옮겨 본 트리 구성. STL은 SCNGeometry로 직접 파싱(Swift 자체 구현). attribution: `vendor/robotis-op2-common/LICENSE` 원본 동봉. |

## 알려진 출처별 기본 라이선스 (Phase 1 선조사)

- `github.com/ROBOTIS-GIT/*`: Apache 2.0 (확인됨)
- `github.com/Interbotix/HROS5-Framework`: GPL v3 (격리됨)
- `github.com/HumaRobotics/darwin_description`: BSD-2-Clause
- `github.com/cyberbotics/webots`: Apache 2.0
- ROBOTIS e-Manual / `emanual.robotis.com`: ⓒ ROBOTIS, 출처 명시 인용 가능
- `ROBOTIS-OP-Series-Data` PDF: ⓒ ROBOTIS, 비상업 인용 가능
- UPennalizers / RoboCup 팀 코드: 저장소별 확인 필요 (코드 복사 시 검증)

## GPL 격리 규칙

GPL 코드(#5 등)는:
1. **코드 복사 금지** — 한 줄도 우리 src/에 들어가면 안 됨.
2. **알고리즘 인용 OK** — "이 패턴은 HROS5에서 영감을 받음"이라고 commit log·주석에 명시 가능.
3. **별도 프로세스** — Webots처럼 우리 앱 외부에서 실행되는 도구로는 사용 가능.

위반 발견 시 즉시 PR 차단 → BLOCKERS.md에 기재 → 격리 후 재PR.

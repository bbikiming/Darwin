# vendor/LICENSES.md

> 외부에서 가져온 코드·리소스의 라이선스를 누적 기록. 매 임포트마다 추가.
> 비호환 발견 시 (예: GPL ↔ Apache 2.0 코어 결합) 즉시 격리하고 `BLOCKERS.md`에 기재.
>
> 최종 갱신: 2026-05-12 (Phase 1 확장 — 커뮤니티 모션 DB 구축으로 #9..#12 추가)

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
| 9 | [darwinop-ens/darwin-op](https://github.com/darwinop-ens/darwin-op) (`fe301d0`) | Apache 2.0 (ROBOTIS upstream 상속) | `research/community/darwinop-ens-darwin-op/` (클론 보존) | ✅ | OP1 framework SourceForge GitHub 미러 — 가장 깔끔. Sprint 5 walking·Sprint 3 motion 1차 reference. ROBOTIS 저작권 라인 보존 필수. |
| 10 | [NimbRo/nimbro-op](https://github.com/NimbRo/nimbro-op) (`5572d41`) | BSD-3-Clause (`software/`) · CC BY-NC-SA 3.0 (`hardware/CAD/`) | `research/community/nimbro-op/` (클론 보존) | ✅ (SW만) / ⚠ (CAD 비상업, ShareAlike — 코어 임베드 X) | 25-patch 의 알고리즘 인용. BSD-3 LICENSE 저작권 텍스트는 본 LICENSES.md 의 "BSD-3 누적 저작권" 절에 캡처. |
| 11 | [Interbotix/HROS5-Framework](https://github.com/Interbotix/HROS5-Framework) (`a0640f1`) | **GPL v3** | `research/community/_gpl-isolated/HROS5-Framework/` (격리 보존) | **❌ (격리)** | 코드 임포트 절대 금지. 알고리즘·페이지 헤더 메타데이터 (사실) 인용만 OK. 격리 규칙 → `research/community/_gpl-isolated/README.md`. |
| 12 | [PersonalAssistantGradProject/robot_personal_assistant_op2](https://github.com/PersonalAssistantGradProject/robot_personal_assistant_op2) (`f6cfc3a`) | `package.xml` 의 `<license>TODO</license>` — **실질 미선언** | `research/community/robot_personal_assistant_op2/` (클론 보존) | ❓ **보류** | OP2 ergonomic + 인사 페이지 메타 (사실) 인용 OK. 코드·바이너리 직접 임포트는 저자 명시적 허가 전까지 금지. README/PDF 텍스트는 출처 명시 후 인용 가능. |

## BSD-3 누적 저작권 (인용 시 보존)

### NimbRo-OP (#10)

```
Copyright (c) 2012, Autonomous Intelligent Systems Group, Rheinische
Friedrich-Wilhelms-Universität Bonn
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  * Neither the name of Rheinische Friedrich-Wilhelms-Universität Bonn
    nor the names of its contributors may be used to endorse or promote
    products derived from this software without specific prior written
    permission.
```

(원문 → `research/community/nimbro-op/LICENSE`)

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

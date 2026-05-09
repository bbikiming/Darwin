# vendor/LICENSES.md

> 외부에서 가져온 코드·리소스의 라이선스를 누적 기록. 매 임포트마다 추가.
> 비호환 발견 시 (예: GPL ↔ Apache 2.0 코어 결합) 즉시 격리하고 `BLOCKERS.md`에 기재.

## 우리 프로젝트 라이선스

**Apache 2.0** (사용자 결정, 2026-05-09).

## 호환성 매트릭스

| 우리 코어가 직접 임포트해도 되는가? | Apache 2.0 | MIT | BSD-2/3 | LGPL | **GPL** | 독점 |
|--------------------------------------|:----------:|:---:|:-------:|:----:|:-------:|:----:|
| 라이브러리 정적 링크                 | ✅          | ✅   | ✅       | ⚠️    | ❌       | 사례별 |
| 코드 부분 인용 (재구현 참고)         | ✅          | ✅   | ✅       | ✅    | ⚠️       | ❌    |
| 텍스트·문서 인용                     | ✅          | ✅   | ✅       | ✅    | ✅       | 출처 명시 |

⚠️ = 동적 링크/별도 프로세스 분리 등 조건부 가능. 케이스마다 확인.

## 인덱스 (Phase 1에서 채워짐)

| # | 출처 | 라이선스 | 사용 위치 | 비고 |
|---|------|----------|-----------|------|
| _ | _    | _        | _         | _    |

## 알려진 출처별 기본 라이선스 (Phase 1 사전 조사)

- `github.com/ROBOTIS-GIT/*` (대부분): Apache 2.0
- `github.com/ROBOTIS-GIT/DynamixelSDK`: Apache 2.0
- `github.com/Interbotix/HROS5-Framework`: **GPL v3** (코어에 임베드 불가, 참고만)
- `github.com/HumaRobotics/darwin_description`: BSD-2-Clause
- `github.com/cyberbotics/webots`: Apache 2.0
- ROBOTIS e-Manual / `emanual.robotis.com`: ⓒ ROBOTIS, 출처 명시하에 인용
- `ROBOTIS-OP-Series-Data` PDF: ⓒ ROBOTIS, 비상업 인용 가능

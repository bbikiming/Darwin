# BLOCKERS

> 자율 실행 중 막힌 항목을 적는다. BLOCKER가 비어 있으면 다음 단계로 자동 진행.

| # | 발생 단계 | 항목 | 상태 | 비고 |
|---|-----------|------|------|------|
| _ | _         | (없음) | _    | _    |

## 잠재 위험 항목 (선제 인지)

- **Mac 빌드 검증 불가**: 컨테이너에 swift/Xcode 미설치. SwiftUI 코드는 작성하되 컴파일 검증은 사용자 Mac에 위임. 보고서에 `swift build` 명령어 명시.
- **실기기 통합 테스트 불가**: USB로 실제 OP1/OP2와 통신은 Mac에서만 가능. Rust 단위 테스트는 가짜 시리얼 백엔드(loopback) 사용.
- **emanual.robotis.com WebFetch 차단**: 자동 수집은 GitHub 저장소와 ROBOTIS-OP-Series-Data PDF 위주.
- **펌웨어 업로드**: 부록 A에 따라 사용자 명시 확인 전 절대 수행 금지. Sprint 5 이전에는 토픽으로 다루지 않음.
- **GPL 코드 임베드 위험**: ROS 일부 패키지·HROS5-Framework가 GPL. `vendor/LICENSES.md`로 격리·기록만 하고 코어에 직접 임베드하지 않음.

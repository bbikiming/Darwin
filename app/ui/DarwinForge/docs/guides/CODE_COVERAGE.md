# Code Coverage

## 측정

Darwin 프로젝트 루트에서:

```bash
bash scripts/coverage.sh
```

DarwinForge 디렉토리 내에서 직접 실행할 경우:

```bash
bash ../../../scripts/coverage.sh
```

## Threshold

- 기본값: **80%** (SonarQube Sonar way 기준)
- `COVERAGE_THRESHOLD` 환경 변수로 override 가능

```bash
# 임계값을 25%로 낮춰서 실행 (현재 baseline 수준)
COVERAGE_THRESHOLD=25 bash scripts/coverage.sh
```

## 현재 상태 (2026-05-24 baseline)

| 측정 기준 | Coverage |
|-----------|----------|
| Line | 19.14% |
| Function | 24.63% |
| Region | 25.65% |

80% 미달 상태. 상세 분석은 `docs/architecture/coverage-baseline-2026-05-24.md` 참조.

## 내부 동작

1. `swift test --enable-code-coverage` 실행 (약 2.5분)
2. `.build/arm64-apple-macosx/debug/codecov/default.profdata` 생성 확인
3. `xcrun llvm-cov report` 로 소스 파일별 coverage 출력
4. TOTAL 행의 Lines Cover% 추출
5. threshold 비교 후 pass/fail 종료 코드 반환

## CI 통합 (향후)

GitHub Actions 예시:

```yaml
- name: Run tests with coverage
  run: bash scripts/coverage.sh
  env:
    COVERAGE_THRESHOLD: 80
```

pre-push hook 예시 (`.git/hooks/pre-push`):

```bash
#!/bin/bash
COVERAGE_THRESHOLD=25 bash scripts/coverage.sh
```

## 주의사항

- `swift test --enable-code-coverage` 는 일반 `swift test` 보다 약 20% 느림
- Tests/, Mocks/ 패턴 파일은 보고서에서 제외됨
- SwiftUI View 파일은 런타임 렌더링 의존성으로 단위 테스트 coverage가 0%로 측정됨 (정상)

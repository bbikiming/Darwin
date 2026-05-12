# research/community/_gpl-isolated/

> **⚠ GPL 격리 영역.** 이 디렉토리 하위의 코드·바이너리·헤더는 `forge-core`, `forge-cli`,
> `DarwinForge` SwiftPM 패키지 등 우리 Apache 2.0 코어로 **임포트·복사 금지**.
>
> 허용되는 사용:
> 1. **알고리즘 인용** — README/주석에 "이 패턴은 HROS5 에서 영감을 받음" 식 명시.
> 2. **메타데이터 추출** — `motion_4096.bin` 의 페이지 헤더 (이름·길이·next/exit) 등 **사실(facts)**
>    수준 정보는 `motions/external/_catalog/*.csv` 로 추출해서 인용 가능.
> 3. **별도 프로세스 실행** — Webots 처럼 우리 앱 외부에서 실행되는 도구로 사용 가능.
>
> 위반 발견 시 즉시 PR 차단 → `BLOCKERS.md` 에 기재 → 격리 후 재PR.
> 호환성 매트릭스는 [`vendor/LICENSES.md`](../../../vendor/LICENSES.md) 참조.

## 격리 대상

| 디렉토리 | 라이선스 | 추출 인용 위치 |
|----------|----------|----------------|
| `HROS5-Framework/` | GPL v3 (Interbotix HR-OS5) | `motions/external/_catalog/hros5-*.csv`, `research/community/_gpl-isolated/HROS5-Framework/_NOTES.md` |

## 왜 격리하는가

GPL v3 의 strong copyleft 는 우리 Apache 2.0 코어와 **조합(combined work) 시 전체가 GPL 로
재라이선스되어야 함**을 요구한다. 우리는 사용자가 Apache 2.0 하에 자유롭게 fork/배포할 수
있어야 하므로 GPL 코드의 직접 임포트를 차단한다.

단, GPL 도 다음은 허용한다:
- **공개된 사실 (facts)** — 페이지 인덱스, 헤더 필드 값, 변경 알고리즘 설명 등.
- **API 의 추상 디자인** — 함수 시그니처를 깨끗한 방으로 재구현 (clean-room) 가능.
- **별도 프로세스 호출** — 우리 앱이 GPL 바이너리를 spawn 해서 stdin/stdout 으로 통신.

## 사용 흐름

```sh
# 페이지 메타데이터 추출 (사실 인용 — GPL 무관)
python3 scripts/research/extract_motion_pages.py \
  research/community/_gpl-isolated/HROS5-Framework/Data/motion_4096.bin \
  --csv motions/external/_catalog/hros5-motion_4096.csv \
  --only-populated

# 알고리즘 학습 — 읽기만, 복사 금지
less research/community/_gpl-isolated/HROS5-Framework/Linux/project/rme/cmd_process.cpp
```

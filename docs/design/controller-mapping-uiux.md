# 콕핏 컨트롤러 매핑 UI/UX 설계 — 레퍼런스 기반 리디자인

작성: 2026-06-10 · 대상: 조종 시뮬 "컨트롤러 연결" 독립 윈도우 (1200×820)
기반 코드: `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/Cockpit/Controller/`

## 결론

현재 매핑 GUI는 모델(바인딩·튜닝·충돌검증)은 충분하나, **"클릭해야 보이는" 구조**가
레퍼런스 대비 가장 큰 약점이다. 핵심 처방은 4가지:

1. **콜아웃 라벨 레이어** (reWASD 패턴) — 모든 컨트롤의 할당 동작을 리더라인 라벨로
   항상 표시. 클릭 없이 전체 매핑을 한눈에 확인.
2. **눌러서 선택** (Steam Input 패턴) — 실패드 입력이 해당 컨트롤을 자동
   선택+하이라이트. Listen 모드와 별개로 탐색 자체가 입력 기반.
3. **라이브 테스터 + 응답 곡선** (Xbox 액세서리/8BitDo 패턴) — 원시 입력 →
   데드존/expo 정형 → 주입 명령까지 파이프라인을 곡선 위 라이브 점으로 시각화.
4. **변경 피드백 토스트 + 실행취소** — 모든 바인딩 변경에 "A ← 볼 트래킹 (X에서
   이동)" 토스트와 1-스텝 undo. 스왑이 조용히 일어나는 현재 동작을 가시화.

## 레퍼런스 조사 요약

| 프로그램 | 채택할 패턴 | 비고 |
|---|---|---|
| Steam Input | 실버튼 누르면 해당 컨트롤로 포커스 이동, 액션 셋(레이어) | 콜아웃+풀 다이어그램의 원조 |
| reWASD | 컨트롤러 이미지 중심 + 리더라인 콜아웃 라벨 상시 표시, 그룹별 색 코딩 | 시각 명료성의 기준점 |
| Xbox 액세서리 | 매핑 화면과 분리된 "컨트롤러 테스트" 탭, 프로파일 슬롯 | 테스터 = 검증 단계 분리 |
| 8BitDo Ultimate | 스틱/트리거 곡선 그래프에 라이브 입력 점, 클릭-선택→우측 편집 | 현 3-컬럼과 동일 골격 |
| DS4Windows | 테이블 뷰 병행, 프로파일 import/export | 현 "목록" 모드와 부합 |
| JoyToKey | (반면교사) 순수 테이블만 — 빠르나 공간감 부재 | 다이어그램 우선 근거 |

## 설계

### A. 다이어그램 콜아웃 레이어 (P1 — 최대 효과)

- `RGG01ControllerVisual` 좌우에 라벨 컬럼 추가. 각 컨트롤 → 리더라인 → 라벨
  (`버튼명 · 동작명`). 라벨 탭 = 해당 컨트롤 선택(기존 onElementTap 재사용).
- 색 코딩(범례 1줄 고정): 이동·회전=청록, 머리=보라, 안전=빨강(잠금 글리프),
  보조(데드맨/터보)=황색, 미설정=회색 점선.
- 라이브 입력 시 라벨도 함께 글로우 — 다이어그램과 라벨의 1:1 대응을 학습시킴.
- 버튼 모드(activator)는 라벨 우측 글리프로: hold=⬇, toggle=⇄, double=··,
  longPress=⏺. (드라이버 소비는 C 단계)
- 구현 접점: `RGG01ControllerVisual.swift` 좌우 여백 확장 + 콜아웃 서브뷰,
  매핑 데이터는 `ControllerBindingProfile.bindings` 역인덱스(binding→action).

### B. 눌러서 선택 + 변경 토스트 (P1)

- 매핑 탭에서 실패드 버튼/축 입력(임계 0.5)이 들어오면 해당 컨트롤을
  선택 상태로 전환(기존 Listen 캡처 로직 `ControllerBindingCapture.detect` 재사용,
  바인딩은 하지 않고 선택만).
- 바인딩 변경(클릭-투-바인드, Listen, 드롭다운 모두) 시 하단 토스트:
  `"{버튼} ← {동작}"` + 스왑 발생 시 `"({기존동작}은 미설정됨)"` + 실행취소 버튼.
- undo는 직전 `ControllerBindingProfile` 스냅샷 1개 보관(불변 값 타입이라 비용 0).

### C. 라이브 테스터 모드 (P2)

- 헤더 세그먼트: `매핑 | 테스트`. 테스트 모드에서는 바인딩 편집 잠금, 다이어그램
  전체가 입력 모니터로 동작(이미 라이브 피드백 있음).
- 인스펙터 자리에 파이프라인 패널: 원시 축값 → 정형 곡선(데드존 음영 + expo 곡선
  + 라이브 점, `ControllerAxisTuning.shaped()` 그대로 시각화) → 최종 주입값
  (`ResolvedControllerInput`).
- 30Hz 폴링 기존 경로 재사용. 신규 View: `AxisResponseCurveView` (Canvas).

### D. 검증 레일 (P2)

- 시트 하단 고정 1줄: 충돌 0 + 안전 바인딩 OK = 초록 / 충돌 시 주황 배너
  ("RB가 터보·복구에 중복 — 클릭해 이동"). 클릭하면 충돌 컨트롤 선택 +
  다이어그램에서 양쪽 펄스.
- 기존 `ControllerBindingProfile.conflicts()` 결과를 그대로 표시. 저장 게이트는
  현행 validate 유지.

### E. 프로파일 칩 (P3)

- 헤더에 프로파일 칩 행: 현재 프로파일 + "+ 프로파일". 슬롯 전환(Xbox 액세서리
  패턴), 기존 export/import JSON(PROF-03)을 칩 컨텍스트 메뉴로 노출.
- 저장 키 `cockpit.controller.binding.profile.v1` → 슬롯 배열로 확장 필요
  (v2 마이그레이션, 기존 v1은 슬롯 0으로 흡수).

### F. 정직성 부채 해소 (병행)

- M3로 미뤄둔 activator/데드맨/터보의 **드라이버 소비**가 들어오기 전까지, 해당
  설정 UI에는 "표시 전용 — 주행 미적용" 배지를 유지한다(현 라벨 정책과 일관).
- `CockpitControllerDriver.tick()`에 `ActivatorState.updated()` 상태머신 통합이
  들어오면 배지 제거.

## 단계별 적용 (HARD-GATE: 구현 전 본 설계 승인 필요)

| 단계 | 내용 | 주요 파일 | 규모 |
|---|---|---|---|
| P1 | 콜아웃 레이어 + 눌러서 선택 + 토스트/undo | RGG01ControllerVisual, CockpitControllerSettingsSheet | 중 |
| P2 | 테스터 모드 + 응답 곡선 + 검증 레일 | SettingsSheet, 신규 AxisResponseCurveView | 중 |
| P3 | 프로파일 슬롯 (저장소 v2) | ControllerBindingProfileStore | 소 |
| 병행 | activator/데드맨 드라이버 소비 | CockpitControllerDriver | 중 |

테스트: 각 단계 순수 로직(역인덱스, undo 스냅샷, 곡선 정형값)은 기존
`DarwinForgeUITests` 패턴으로 단위 테스트 우선 작성. Swift 테스트는 직렬 실행.

# RoboPlus Action `.mtn` 파일 포맷

> ROBOTIS의 모션 저작 도구 RoboPlus Action이 생산하는 `.mtn` 파일을 우리
> Mac 앱이 import/export 무손실로 처리해야 한다.
>
> 본 문서는 Phase 2 명세. Sprint 3 파서가 이 명세로 작성된다. 일부 항목은
> 업스트림 코드를 직접 읽기 전까지 `> TODO: needs verification` 표시.

## 개요

- 형식: 텍스트 기반(ASCII), 줄 단위 레코드. (ROBOTIS의 일부 새 도구는 바이너리 `motion_4096.bin`을 직접 다루지만, `.mtn`은 사람이 읽을 수 있는 형태)
- 단위: 페이지(Page) 다수를 한 파일에 담음. 일반적으로 1 파일 = 1 모션 라이브러리.
- 인코딩: UTF-8 (ROBOTIS 한국어 도구는 EUC-KR을 쓰는 변형도 있음 — 우리는 UTF-8 strict, EUC-KR은 변환 후 임포트).

## 레코드 구조 (현재 이해 — Phase 2)

```
type=1
versn=2
title=
                                ...
page_begin=
name=Stand Up
compliance=5,5,5,5,5,5, ...
play_param=0,0,32,0,0,0,0,0
step=
0,2048,2048,2048, ..., 0, 0, 32        # 20개 관절 위치 + 시간 + 옵션
step=
...
exit=
page_end=
page_begin=
name=Walk Ready
...
page_end=
```

> TODO: needs verification — 정확한 헤더 키, 필드 순서, end-of-line 규약은 `darwinop-ens` 미러의 `Linux/project/action_editor/` 와 `Framework/src/motion/Action.cpp`를 직접 읽고 확정. Sprint 3 시작 전에 cross-check.

## 핵심 개념

### Page
하나의 의미 있는 모션 단위 (예: "안녕 손짓", "기본 자세", "발차기"). 최대 7개의 Step을 담는다. 각 페이지는:
- `name`: 사람이 읽을 라벨
- `compliance[20]`: 관절 강성 0..7 (모터 P-gain 환산)
- `play_param`: 다음 페이지 ID, 정지 시 페이지 ID, 재생 속도, 반복 횟수 등
- `step[N]`: N개 키프레임

### Step
하나의 키프레임. 다음 필드:
- `pose[20]`: 20개 관절의 4096-step 위치 (MX-28의 Goal Position과 동일 단위, 0..4095)
- `pause_time`: ms — 도달 후 대기
- `play_time`: ms — 이 자세로 보간하는 시간
- `option`: 비트 플래그 (다음 step skip 등)

### Pose
한 시점의 20관절 각도 스냅샷. Step에 임베드되거나 Action Editor에서 별도 저장.

## 포맷 변환 정책

| 입력 형식 | 우리 처리 |
|-----------|-----------|
| `*.mtn` (UTF-8) | 1차 — 직접 파싱 |
| `*.mtn` (EUC-KR) | 텍스트만 UTF-8로 변환 후 동일 파싱 |
| `motion_4096.bin` (CM 내부) | Sprint 3 마지막에 추가 — 페이지/스텝 메모리 레이아웃 별도 명세 (`page-format.md`) |
| 우리 내부 JSON | Sprint 3 — 단방향 export, import도 무손실 round-trip |

## 무손실 round-trip 정의

`load(.mtn) → write(.mtn)` 결과가 입력과 byte-by-byte 동일해야 한다 (개행 정규화 제외).

## 출처 (Sprint 3 시작 시 확정)

- `research/robotis-official/ROBOTIS-OP-Series-Data/ROBOTIS-OP, ROBOTIS-OP2/Tutorials/` (사례 파일)
- `darwinop-ens/darwin-op` SourceForge 미러 — `Linux/project/action_editor/`
- ROBOTIS RoboPlus Action 매뉴얼 (사용자 Mac에 설치 시 PDF 동봉)

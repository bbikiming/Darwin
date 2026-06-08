# Switch Cockpit Layout System

작성일: 2026-06-06

## 목적

DARwIn Switch 조종석의 패딩, 갭, radius, 패널 구성을 1280x720 Switch 휴대 화면에 맞는 반복 가능한 디자인시스템으로 정리한다. 목표는 "큰 요소를 많이 배치한 화면"이 아니라, 조종 중 눈이 빠르게 훑을 수 있는 규칙적인 조종 패널이다.

## 기준

- 기준 캔버스: 1280x720.
- 기본 리듬: 4px 기반.
- 반복 갭: 프레임/큰 영역 10px, 카드 내부 8-12px.
- radius: 일반 패널/버튼 8px, 내부 focus/소형 control 6px.
- 패딩: 앱 외곽 14px, 일반 패널 12px, 카드 좌우 14px.
- 하단 dock, 상단 bar, 좌우 rail은 고정밀 조종 화면이므로 높이와 열 폭을 토큰화한다.

## CSS 토큰

`tools/switch-pilot/web/styles.css`의 `:root`에 다음 성격의 토큰을 추가했다.

| 토큰 그룹 | 용도 |
| --- | --- |
| `--space-*` | 4-24px 간격 scale |
| `--gap-frame` | 상단/중앙/하단 frame 간격, playfield gap |
| `--gap-card` | 카드 또는 버튼 내부의 중간 간격 |
| `--gap-tight` | panel head, compact list 등 좁은 간격 |
| `--pad-shell` | 전체 viewport 외곽 padding |
| `--pad-panel` | side rail과 일반 panel padding |
| `--radius-panel` | 주요 panel/button radius, 8px |
| `--radius-inner` | 내부 focus ring/control radius, 6px |
| `--topbar-h`, `--readout-h`, `--dock-h`, `--rail-w` | Switch 720p cockpit 고정 구조 |

## 적용 범위

- 전체 shell: grid row, gap, outer padding.
- top HUD: title lockup, mode switch, status chip.
- Joy-Con rail: rail gap, rail padding, tag radius, stick spacing.
- stage panel: mission strip padding/gap, camera HUD, camera overlay.
- dashboard mode: instrument panel gap/padding, card heading, system tiles, connection row.
- readout grid: panel padding, head gap, meter row gap, connection list gap.
- action dock: dock padding/gap, button padding/gap, focus inset.

## 유지한 값

게이지 눈금, reticle, robot figure limb 위치, mini-stick 실제 크기처럼 시각물의 형태를 만드는 픽셀값은 토큰화하지 않았다. 이 값들은 간격 시스템이 아니라 그래픽 자체의 비율이므로, 변경 시 별도 시각 QA가 필요하다.

## 검증 기준

- 1280x720 캡처에서 외곽/rail/stage/dock 간격이 규칙적으로 보여야 한다.
- 계기판 모드에서 중앙 panel과 하단 dock이 서로 겹치지 않아야 한다.
- 모델/카메라 모드에서도 camera HUD와 overlay가 같은 spacing scale을 사용해야 한다.
- 텍스트가 버튼/카드 내부에서 잘리지 않아야 한다.

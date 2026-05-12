# 07. 일반 UI / UX 패턴

> 대화 AI나 로봇과 직접 무관하지만, DarwinForge UI 다듬을 때 참고할
> 표준·패턴·디자인 시스템.

## 인덱스

| 파일 | 주제 |
|------|------|
| [node-flow-editors.md](node-flow-editors.md) | 노드 플로우 에디터 (Blender, Houdini, TouchDesigner, n8n, Unreal Blueprints) |
| [timeline-editors.md](timeline-editors.md) | 타임라인 에디터 (After Effects, Pro Tools, FCPX, Ableton) |
| [design-system-references.md](design-system-references.md) | 디자인 시스템 (Linear, Raycast, Things 3, Arc, Apple HIG) |
| [korean-ux.md](korean-ux.md) | 한국어 UX (토스 8원칙, 카카오, 네이버, 라이팅) |
| [safety-color-iconography.md](safety-color-iconography.md) | 안전 색·아이콘 표준 (KS S ISO 7010, ISO 13850, Apple HIG) |
| [accessibility.md](accessibility.md) | 접근성 (WCAG 2.3, Apple Accessibility) |
| [3d-pose-visualization.md](3d-pose-visualization.md) | 휴머노이드 3D 시각화 (RViz, Foxglove, URDF viewers) |

## DarwinForge UX 원칙 (현행)

이미 채택:
1. **macOS HIG 우선** — NavigationSplitView, Material 폴백, NSColor
2. **한국어 해요체 통일** — `KoreanUX.swift` 50+ 메시지
3. **8pt 그리드** — `DFSpace.{xs, sm, md, lg, xl}`
4. **3중 의미 (색 + 아이콘 + 텍스트)** — 색맹·시각 장애 대응
5. **ISO 13850 e-stop** — 좌상단 항상 가시
6. **단축키 1차** — `⌘1` 대화, `⌘⇧E` 전문가 모드, `ESC` e-stop

후속 후보:
- 노드 플로우 에디터 (Strategy FSM, Behavior Tree)
- 타임라인 에디터 (모션 키프레임)
- VoiceOver / 한국어 음성 라벨 보강
- 3D pose preview (URDF + SceneKit)

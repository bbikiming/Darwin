# Synth Palette — Sprint 11 (SwiftUI)

ROBOTIS-OP2 모션 합성 UI. PRD-001 §6.4 명세.

## 구성

```
Sources/DarwinForgeUI/Synth/
├── SynthPaletteView.swift     ─ 3-pane 메인 view
├── SynthLibraryPanel.swift    ─ 좌측: 카탈로그 16 페이지 카드 + safety filter
├── SynthCanvasPanel.swift     ─ 중앙: 사용자가 모은 페이지 + 결과 JSON
├── SynthInspectorPanel.swift  ─ 우측: 연산자 + 파라미터 + Validator overlay
├── SynthModel.swift           ─ @MainActor ObservableObject 상태
└── README.md                  ─ 본 문서

Sources/ForgeCore/SynthBridge.swift
                               ─ `forge synth ...` CLI 외부 호출 wrapper
```

## RootView 통합 (Pending)

본 view 는 standalone 으로 작성. RootView 의 `Section` enum 에 추가하려면:

```swift
// RootView.swift Section enum
enum Section {
    case studio, teach, motion, walk, conversation, remote, expert
    case synth   // 신규
}

// destination 표시
case .synth: SynthPaletteView()
```

**RootView 수정은 Sprint 11 본 commit 에서 의도적으로 회피** — 병행 진행 중인
다른 worktree GUI 작업과의 충돌 방지. 머지 시점에 사용자가 직접 통합.

## 호출 방법 (RootView 통합 전)

`DarwinForgeApp.swift` 의 임시 진입점 또는 NavigationLink 로 호출 가능:

```swift
NavigationLink(destination: SynthPaletteView()) {
    Label("Motion Synthesis", systemImage: "wand.and.sparkles")
}
```

또는 sheet:

```swift
.sheet(isPresented: $showingSynth) {
    NavigationStack {
        SynthPaletteView()
    }
}
```

## 의존성

- `ForgeCore.SynthBridge` — `Process` 로 `cargo run -p forge-cli -- synth ...` 호출.
- macOS sandbox entitlement 가 외부 명령 실행 허용해야 함.
- `FORGE_MOTION_BIN` env (선택) — 비표준 motion_4096.bin 경로.

## 안전 정책

- **Commit 버튼 없음** — UI 에서 `motion_4096.bin` 직접 수정 금지. JSON 결과만
  보여줌. Commit 은 `forge synth commit <page.json>` 또는 `/synth` 슬래시 →
  사용자 명시 확인 후만.
- **Validator overlay** — 결과의 4 stage 상태를 색상 / 아이콘으로 표시.
- **단순 호출 only** — Sprint 11 본 view 는 Sequence / Mutate / Mirror 만 지원.
  Layer / Morph / Procedural 은 후속 Sprint 또는 `forge` CLI 사용.

## 후속 작업 (Sprint 12+ 또는 PR 머지 후)

1. RootView 통합 — `Section.synth` + Toolbar 단축키 (`⌘6`?)
2. Drag-and-drop — 라이브러리 카드 → 캔버스 row 드래그
3. 3D Preview — 합성 결과를 `RobotScene3D` 에서 재생
4. Validator 실시간 실행 — Synthesize 후 `forge synth validate` 자동 호출
5. Commit dialog — slot 입력 + force checkbox + 사용자 확인 alert
6. Layer / Morph / Procedural 본구현

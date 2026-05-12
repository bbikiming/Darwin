# Claude.ai — Anthropic 대화 인터페이스

## 한 줄 소개

Anthropic의 공식 Claude 웹/데스크탑 앱. DarwinForge의 직접적 본보기.

## 핵심 UI 요소

### 1. 메시지 흐름

```
┌──────────────────────────────────────────────────────┐
│ ← [채팅 사이드바]  [현재 채팅 제목]   [공유] [설정]  │
├──────────────────────────────────────────────────────┤
│                                                       │
│  [사용자] 메시지                                      │
│                                                       │
│  [Claude] 메시지                                      │
│   ┌───────────────────────────────────────────────┐ │
│   │ 도구 호출 (artifact, tool_use)                 │ │
│   └───────────────────────────────────────────────┘ │
│                                                       │
│  [입력 영역]                                          │
│   ┌─────────────────────────────────────┐ [📎] [↑]  │
│   │ Reply to Claude…                    │            │
│   └─────────────────────────────────────┘            │
└──────────────────────────────────────────────────────┘
```

### 2. Artifacts (★ 핵심 차용)

긴 코드 / 문서 / HTML을 대화 인라인이 아닌 **우측 별도 패널**에 렌더링.
사용자가 토글로 채팅에 합치거나 분리 가능.

DarwinForge 매핑:
- `NavigationSplitView` 우측 detail 영역에 동적으로 artifact 카드
- 모션 JSON, 워크 트레이스 표, 3D pose preview 등을 artifact로

### 3. Projects

여러 채팅을 하나의 "프로젝트"로 묶고 공유 system prompt + 파일 컨텍스트
적용. 우리에 매핑하면:
- 로봇별 프로젝트 ("Darwin-1G", "Darwin-2G")
- 각 프로젝트가 자기 캘리브레이션 / 모션 라이브러리 / 안전 한계 보존

### 4. File uploads

PDF / 이미지 / CSV를 첨부하면 Claude가 컨텍스트로 활용. DarwinForge에선:
- `.mtn` 파일 직접 채팅에 드래그 → 자동 분석 / 재생 제안
- IMU 트레이스 CSV → "왜 넘어졌어?" 같은 분석 질의

### 5. Memory (Projects + Across chats)

장기 기억. DarwinForge에선:
- "Darwin-1G의 R_HIP_YAW가 자주 막힘" 같은 사용자 메모를 시스템 prompt에
  자동 주입

## 단축키

- `⌘N` — 새 채팅
- `⌘L` — 사이드바 토글
- `↑` (input 비어있을 때) — 마지막 메시지 편집
- `Esc` — 입력 취소

## 색상 팔레트 (관찰)

- Background: `#FAFAF8` (warm white) — 우리도 비슷
- Accent: `#CC785C` (Anthropic copper) — 우리는 macOS Accent로 간소
- Sidebar: `#F0EFE8` — 우리도 system controlBackground

## DarwinForge 차용 — 적용 / 미적용

### 적용 ✅
- 메시지 흐름 (user / assistant / tool / error)
- 입력 바 with submit button + ⌘↩
- Empty state suggestion chips

### 미적용 — 후보
- ★★★ Artifacts 패널 (NavigationSplitView 우측 활용)
- ★★ Projects (= Robot 별 컨텍스트 분리)
- ★ File uploads (드래그 앤 드롭)
- ★ Memory across chats

## 출처

- Claude.ai: https://claude.ai
- Artifacts 가이드: https://www.anthropic.com/news/artifacts
- Projects: https://www.anthropic.com/news/projects
- Anthropic Best Practices (tool use): https://docs.anthropic.com/en/docs/build-with-claude/tool-use/overview

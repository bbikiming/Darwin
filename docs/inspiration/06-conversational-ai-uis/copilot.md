# GitHub Copilot Workspace — Specification + Plan + Code

## 핵심 UI 요소

### Plan Mode

3단계 흐름:
1. **Specification** — 사용자가 자연어로 의도 작성 (또는 issue link)
2. **Plan** — Copilot이 구체적 단계 출력. 사용자가 단계 추가/삭제 가능.
3. **Implementation** — 단계별 변경 적용. 각 변경마다 diff 검토.

DarwinForge 매핑:
- Specification = 사용자의 채팅 첫 메시지
- Plan = Claude의 plan output (현재 implicit)
- Implementation = Tool call execution

### HITL at every step

각 단계 사이 사용자가 명시적 OK. **편집·재시도·중단** 모두 가능.
LangGraph의 4가지 상호작용 패턴을 깊게 구현 — 이 부분 우리 IntentDispatcher에서
참고할 만함.

## DarwinForge 차용

★★ — Plan-then-execute 패턴 (Sprint 8 후보, Replit Agent와 동일).
★ — Specification 단계의 명시적 분리는 우리 채팅에서 첫 메시지가 그 역할.

## 출처

- GitHub Copilot Workspace: https://githubnext.com/projects/copilot-workspace
- 발표 블로그: https://github.blog/news-insights/product-news/github-copilot-workspace/

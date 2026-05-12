# 09. 학술 논문 + 인용

> DarwinForge 알고리즘 / UI / LLM 통합의 학술적 근거. BibTeX 형식 +
> 분야별 큐레이션.

## 인덱스

| 파일 | 주제 |
|------|------|
| [classics.md](classics.md) | 휴머노이드 / 모션 / 컨트롤 고전 (1990~2015) |
| [recent-2024-2026.md](recent-2024-2026.md) | LLM-로봇 최신 (2024~) |
| [humanoid-locomotion.md](humanoid-locomotion.md) | 워킹 / ZMP / MPC / RL gait |
| [manipulation-survey.md](manipulation-survey.md) | 매니퓰레이션 (DarwinForge 직접 무관, 참고) |
| [BIBLIOGRAPHY.bib](BIBLIOGRAPHY.bib) | 통합 BibTeX |
| [USER_GUIDE_PROMPT.md](#) | (저장소 루트의 USER_GUIDE_PROMPT.md 참조) |

## 우리 코드의 근거가 되는 핵심 논문

### Walk Engine (forge-core::walk)
- [Ha et al. 2011] — DARwIn-OP 발표 + ZMP 워킹
- [McGill et al. 2010] — UPenn / Team DARwIn 워크 + 비전

### Strategy FSM (forge-core::strategy)
- (전통 FSM) — 새 학술 인용 없음. RoboCup 통합 패턴 참조.

### LLM 안전 (5계층)
- [Anthropic 2022] Constitutional AI
- [Bai et al. 2022] HHH (Helpful-Honest-Harmless)
- [LangGraph 2024] Approve / Edit / Reject / Respond 패턴

### Sim-to-Real
- [OpenAI 2019] Solving Rubik's cube with a Robotic Hand (DR + LSTM)
- [Eureka 2023] LLM-generated reward
- [DrEureka 2024] Domain randomization 자동화

# Product Requirements Documents (PRD)

> Darwin Forge의 제품 요구사항 문서 색인.
> ADR(Architecture Decision Record)은 [`../decisions/`](../decisions/) 참조.

## 활성 PRD

| ID | 제목 | 상태 | 대상 스프린트 |
|----|------|------|---------------|
| PRD-001 | [Motion Synthesis Engine v1](motion-synthesis-v1.md) | Draft (구현 대기) | Sprint 9 ~ 12 |
| PRD-002 | [DARwIn FPV — ROG Ally 콕핏 앱](../../app/ally/docs/01_PRD.md) | Draft (W0 골격 기진행) | Ally W0 ~ W4 |

## 상태 정의

- **Draft**: 작성됨. 사용자 승인 전. 구현 금지.
- **Approved**: 사용자 승인 완료. 구현 가능.
- **In Progress**: 해당 스프린트 진행 중.
- **Shipped**: 구현 완료, MVP 정의 충족.
- **Superseded**: 후속 PRD로 대체. (대체 문서로 링크 유지.)

## 작성 규칙

1. 결론은 §0 TL;DR에 한 줄로.
2. §2 목표/비목표를 측정 가능한 기준으로 명시.
3. §10 검증 계획에 단위/통합/사용자 테스트 분리.
4. §11 구현 단계에 Sprint 단위 작업 분해.
5. §13 미해결 질문은 결정 보류 사유와 함께.
6. §14 결정 사항은 D# 번호로 추적.

새 PRD는 본 인덱스에 추가하고, ADR이 필요한 결정은 별도로 `../decisions/`에 생성.

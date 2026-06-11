# 05 — 리뷰 결과 기록부 (Fable Review Result)

> `04_REVIEW_CHECKLIST.md` 검수 결과의 누적 원장. 항목당 1절, 최신이 위.
> Fable = Claude(Fable 5) 검수, Codex = OpenAI Codex 교차 검수. 둘 중 하나 이상 필수.

## 기록 양식

```
## [P#] 제목 — 판정 (날짜)
- 구현 커밋: / 리뷰어: Fable | Codex | both
- A 안전: 통과/이슈 · B 계약: · C 품질: · D 절차:
- 발견 이슈: (심각도, 내용, 수정 커밋)
- 실기 보류 항목: (로봇 연결일 벤치로 이월된 것)
```

---

## [P2] 3D W2 — 화면별 환경 프리셋 + 셰이더 그리드 — **통과** (2026-06-12)

- 구현 커밋: `4c1f6f2` · 리뷰어: Fable(구현 세션) + Codex 교차 검수
- A 안전: 통과(3D 성능 계약 유지 — 30fps·isFullyIdle·wantsHDR=false, 헤드리스 회귀 없음)
- B 계약: 통과(프리셋 주입은 init 단일 경로, legacyGrid 폴백 보존)
- C 품질: `ScenePresetSnapshotTests` 신설, swift test 전체 통과(serial)
- D 절차: README 표·프롬프트 체크박스 갱신 완료
- 발견 이슈: 구현 세션에서 Codex 검수 후 수정 반영(상세는 해당 세션 기록 — 본 원장
  도입 이전이라 이슈 목록 미이관)
- 실기 보류: 없음(UI 전용)

## [P5] bus D0 — J4 deadline + J13 FTDI + 계측 — **통과** (2026-06-11)

- 구현 커밋: `f21f046` · 리뷰어: Fable(구현 세션) + Codex 교차 검수
- A 안전: 통과(E-STOP/cancel 체크 step 경계 유지, phase floor 80ms 유지)
- B 계약: 통과(IOSSDATALAT 미지원 어댑터 no-op 폴백)
- C 품질: `StepDeadlineSchedulerTests`·`PilotLatencyTracerTests` 신설, cargo + swift test 통과
- D 절차: README 표·체크박스 갱신 완료
- 발견 이슈: 본 원장 도입 이전 — 미이관
- 실기 보류: **step 지터 p95 ≤±10ms · USB IMU read p95 ≤3ms** → 로봇 연결일 벤치(02 §2)

---

> 참고: 본 원장은 2026-06-12 하네스 도입 시점부터 운용. 이전 완료분(P2·P5)은 소급
> 기록이며, 이후 항목은 머지 전 기록이 의무다(04 §리뷰 절차 6단계).

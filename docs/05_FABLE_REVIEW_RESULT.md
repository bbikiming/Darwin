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

## [P11] 3D W3 — 로봇공학 오버레이 — **통과** (2026-06-12, 머지 대기)

- 구현: `claude/p11-3d-overlays` 브랜치 3커밋(59c6501 RigSkeleton 선행 → 9471528 오버레이
  본체 → 48ba615 테스트), 베이스 4c1f6f2, 워크트리 /tmp/Darwin-p11(clean 확인)
- 리뷰어: **Fable 교차 리뷰**(구현 세션과 별도 세션 — 04 §D 외부 검수 충족)
- **A 안전·성능: 통과** — Overlays/ 전체에 자체 타이머/asyncAfter/Task 0건(기계 검사),
  노드 풀 init 1회 할당, 갱신은 `refreshOverlays()`가 applyPose 동일 경로에서만 호출
  (RobotSceneCoordinator:163·170·179), 10파일 1,039줄(전부 800줄 이하), renderImage
  확장 후 기존 호출자(SceneExposure/ScenePresetSnapshot) 무회귀
- **B 계약: 통과** — preset×오버레이 기본값 매트릭스가 설계 §5 표와 6×5 전 칸 일치,
  발 사각형/CoM 높이 상수는 `ZMPMonitor` 단일 정의 직접 참조(SupportPolygonGeometry:15-16·81),
  RigSkeleton 선행 커밋으로 프리미티브 폴백 크래시 방지, emission 우선순위
  warn95>warn85>highlight 단일 진입점
- **C 품질: 통과** — 신규 테스트 9개(ZMP 정합 5·emission 2·스냅샷 2) **리뷰 세션에서
  직접 재실행 0 실패**, 풀 스위트 3408 통과(serial)·빌드 clean(구현 세션 증거)
- **D 절차: 통과** — 커밋 3분할(선행/본체/테스트), README·프롬프트 갱신 브랜치 포함
- 발견 이슈: 블로킹 0
- 비고/이월: ① **머지 충돌 표면 7파일** — MeshRig·DarwinOP2Rig·ViewportControls·
  StudioView·MotionStudioCanvas(메인의 미커밋 P12/P3 작업과 교차) + docs/design/README.md·
  implementation-prompts.md(체크 표기 — union 병합) → **메인 정리 후 머지 + 풀 스위트 재실행
  의무** ② Instruments 풀링 실측·오버레이 실데이터(FSR/verdict) 검증은 실기/O4 이후 이월
  ③ 헤드리스 스냅샷은 "off 대비 픽셀 차" 방식 — 로봇 STL 미로드 제약 내 타당

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

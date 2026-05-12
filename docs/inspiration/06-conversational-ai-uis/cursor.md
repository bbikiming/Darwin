# Cursor — AI 코드 에디터

## 핵심 UI 요소

### 1. Inline diff (★★)

AI가 코드 변경 제안 시 **인라인 diff**로 보여주고 사용자가 line별로
Accept / Reject.

DarwinForge 적용:
- 모션 페이지 step 수정 시 "ID 5 위치 2048 → 2200으로 변경" diff 표시
- "Accept all changes" / "Reject" / "Edit further"

### 2. Composer (multi-file edit)

여러 파일을 동시에 편집하는 모드. 사용자가 plan을 보고 한번에 승인.

DarwinForge 매핑:
- "이 모션을 OP1과 OP2 양쪽에 동기화" → 양 로봇 독립 commit + 일괄 승인

### 3. Tab completion (=Claude code edit prediction)

다음 키 입력을 예측해 inline 회색 텍스트로 제안. Tab 키로 수락.

DarwinForge 적용 (덜 확실):
- 명령 입력 중 자동 완성 ("로봇 깨우" → "로봇 깨워줘")

### 4. Composer + Plan mode

복잡 작업은 plan 먼저, 사용자 승인 후 실행. Replit Agent와 유사.

## DarwinForge 차용

★★ — Inline diff (Sprint 10 후보 — 모션 점진 편집)
★ — Composer style multi-file/multi-robot batch
★ — Tab completion (NSTextField 표준 autocomplete로 충분)

## 출처

- Cursor: https://www.cursor.com/
- Cursor docs (Composer): https://docs.cursor.com/composer

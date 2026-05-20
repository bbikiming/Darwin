# WalkLab Claude CLI 분석 통합 검증 보고서

검증일: 2026-05-19  
대상 브랜치: `claude/v1.11.9-walklab-claude-analysis`  
대상 커밋: `53eb44f feat(walklab): v1.11.9 Claude CLI 보행 데이터 분석 통합`

## 결론

v1.11.9는 "보행 데이터를 Claude CLI로 보내 자연어 분석을 받는 진단 보조 기능"으로는 의미가 있다. 하지만 "로봇을 에이전트 기반으로 반복 개선하는 시스템"으로 보기에는 아직 부족하다.

현재 완성도 평가는 다음과 같다.

| 영역 | 완성도 | 판단 |
|---|---:|---|
| 세션 저장/시각화 기반 | 55% | JSONL, summary, 차트, 최근 세션 로딩은 있음. 다만 품질 지표와 실험 컨텍스트가 부족하다. |
| 기존 자동 튜닝 알고리즘 | 30% | intensity 단일 축만 다루며, sagittal fall/앞기울 문제를 충분히 설명하지 못한다. |
| Claude CLI 자연어 분석 UI | 45% | prompt 생성, CLI path 탐지, UI 패널은 구현됨. 실제 분석 품질과 실패 모드는 검증 부족. |
| 에이전트 기반 모션 개선 루프 | 25% | 분석 결과를 구조화된 실험/패치/승인/재측정 루프로 연결하지 못한다. |
| 실로봇 안전 적용 준비도 | 20% | 사람 승인, 거치대 프로토콜, 데이터 품질 gate, 적용 차단 정책이 아직 약하다. |

종합: **약 35% 완성도**. "데이터를 보고 사람이 판단하는 보조 도구" 단계다. "에이전트가 로봇 모션을 신뢰성 있게 개선해 나가는 품질"은 아니다.

## 검증 결과

- `swift test --filter WalkLabV119ClaudeAnalysisTests`: 11 tests, 0 failures
- `swift test`: 445 tests, 0 failures
- 로컬 Claude CLI: `/Users/bbikiming/.local/bin/claude`, version `2.1.138`
- 실제 `claude -p` 모델 호출은 수행하지 않았다. 이유: 로봇 세션 데이터 외부 전송과 비용이 발생할 수 있고, 현재 검증 목적은 코드 구조/품질 점검이기 때문이다.

## 주요 발견

### CRITICAL 1. 8축 분석을 요청하지만 실제 세션별 8축 값이 prompt에 거의 없다

`WalkSessionClaudePrompt`는 8 axis를 설명한다.

- `WalkingEngine`
- `algorithmMode`
- `signConvention`
- `gainProfile`
- `pitchInputConvention`
- `applyToRobot`
- `enableBalanceCorrection`
- `hipPitchOffsetTrimDeg`

하지만 `sessionsSection()`이 Claude에게 넘기는 실제 세션 정보는 `WalkSessionSummary` 중심이다. 현재 summary에는 preset, duration, sampleCount, intensity, pitch/roll 통계, oscillation, effectiveness, recommendedIntensity만 있다.

코드 근거:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionClaudePrompt.swift:49`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionClaudePrompt.swift:80`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionSample.swift:227`

특히 `walkingEngine`, `pitchInputConvention`, `hipPitchOffsetTrimDeg`, `enableBalanceCorrection`, stride/period/footHeight 같은 핵심 값은 summary/header에 충분히 남지 않거나 prompt에 출력되지 않는다.

영향: Claude가 "axis 별 진단"을 하라는 요청을 받지만, 실제로는 어떤 axis 조합에서 나온 데이터인지 모르는 상태로 추론하게 된다. 이러면 자연어 답변은 그럴듯해도 실험 설계에는 위험하다.

### CRITICAL 2. 에이전트 개선 루프가 없다

현재 흐름은 다음 수준이다.

1. 세션 summary 로드
2. phase 통계 일부 계산
3. markdown prompt 생성
4. `claude -p` 호출
5. markdown 결과 표시

분석 결과가 구조화된 `nextExperiment`, `axisChange`, `safetyGate`, `expectedMetric`, `rollbackCondition`으로 저장되지 않는다. 자동 적용은 기존 `WalkSessionAutoTuner`의 intensity 단일 축에만 남아 있고, Claude 결과와 연결되지 않는다.

코드 근거:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkDataView.swift:184`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionClaudeAnalyst.swift:68`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:2867`

영향: 지금은 "분석 리포트 생성"이지 "에이전트 기반 개선"이 아니다. 에이전트가 다음 실험을 제안하고, 사용자가 승인하고, 앱이 안전하게 한 축만 바꿔 실험하고, 전후 데이터를 비교하는 폐루프가 필요하다.

### HIGH 1. 데이터 품질 gate가 Claude prompt와 자동 튜닝에 없다

실로봇 보행 데이터에서 가장 먼저 봐야 하는 것은 결과 metric이 아니라 데이터 품질이다.

필수 품질 지표:

- 실제 로봇 데이터인지, 시뮬/스테일 데이터인지
- sample rate 실측값
- IMU sequence duplicate ratio
- `imuSampleAgeMs > 250ms`, `>= 500ms` 비율
- bus write/read failure delta
- phase 누락률
- candidate/applied delta 누락률
- 낙상/중단/수동 정지 여부

현재 `WalkSessionSample`에는 일부 원천 필드가 있다. 하지만 `WalkSessionSummary`와 Claude prompt에는 품질 요약이 없다.

코드 근거:

- 원천 필드: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionSample.swift:50`
- 원천 필드: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionSample.swift:79`
- prompt 출력: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionClaudePrompt.swift:81`

영향: Claude가 품질이 낮은 데이터를 근거로 모션 개선을 권고할 수 있다. 실로봇에서는 이게 가장 위험하다.

### HIGH 2. 기존 analyzer는 앞기울/전방 낙상 문제에 약하다

`WalkSessionAnalyzer`의 effectiveness는 roll과 R hipRoll delta 중심이다.

코드 근거:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionAnalyzer.swift:50`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionAnalyzer.swift:56`

하지만 사용자가 실제로 겪는 핵심 문제는 "앞으로 잘 나아가지 못함", "앞으로 넘어지려 함", "뒤뚱거림"이다. 이는 sagittal plane, 즉 pitch/hipPitch/knee/anklePitch/foot clearance/period/stride가 중심이다.

현재 analyzer는 pitch 평균은 보지만, pitch 회복 방향/anklePitch delta/hipPitchOffset/stride/period와의 관계를 충분히 계산하지 않는다.

영향: 자동 튜닝이 "강도 level을 올리자/내리자" 같은 단일 축 권고에 갇힌다. 실제 원인이 hipPitch trim, period, foot height, stride, onboard/sparse 차이일 때 잘못된 권고가 나올 수 있다.

### HIGH 3. candidate delta와 applied delta가 분리 분석되지 않는다

`phaseStats`는 R anklePitch delta를 하나만 출력한다. 적용값이 있으면 applied를 우선하고, 없으면 candidate를 쓴다.

코드 근거:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionClaudePrompt.swift:183`

문제는 observeOnly에서는 `appliedDeltas`가 `[0, ...]`이고 `candidateDeltas`는 의미 있는 값을 가질 수 있다는 점이다. 이 경우 현재 통계는 "실제로는 보정 후보가 있었지만 적용은 0"이라는 중요한 차이를 가릴 수 있다.

필요한 출력:

- candidate R/L anklePitch 평균
- applied R/L anklePitch 평균
- candidate와 applied 차이
- observeOnly/applyToRobot 상태
- pitch error와 delta 방향의 상관

### HIGH 4. `WalkLabSession` 통합은 UI에서 실질적으로 쓰이지 않는다

Claude 관련 상태와 함수가 `WalkLabSession`에 추가됐다.

코드 근거:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:2845`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:2867`

하지만 `WalkDataView`는 별도의 `@State`로 `claudeMarkdown`, `claudeError`, `claudeInProgress`, `claudeUserReport`를 들고 직접 `WalkSessionClaudeAnalyst`를 호출한다.

코드 근거:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkDataView.swift:22`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkDataView.swift:156`

영향: "WalkLabSession 통합 완료"라는 보고는 과장이다. 실제 UI 경로와 Session 경로가 이중화되어 유지보수와 상태 불일치 위험이 있다.

### HIGH 5. Claude process 호출 layer가 production-grade가 아니다

현재 `WalkSessionClaudeAnalyst.analyze()`는 `process.waitUntilExit()`로 동기 대기하고, stdout/stderr를 프로세스 종료 후에 읽는다.

코드 근거:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionClaudeAnalyst.swift:93`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionClaudeAnalyst.swift:110`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionClaudeAnalyst.swift:113`

위험:

- 출력이 많을 경우 pipe buffer가 차서 deadlock 가능
- timeout이면 `process.terminate()`만 하고 별도 timeout error가 없다
- CLI path가 `/Users/bbikiming`에 하드코딩되어 이식성이 낮다
- 실제 `claude -p` 호출 성공을 테스트하지 않는다

### MEDIUM 1. prompt injection / 데이터 경계가 약하다

사용자 보고는 그대로 prompt에 들어간다.

코드 근거:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionClaudePrompt.swift:106`

현재는 사용자가 본인 데이터에 메모를 넣는 기능이라 즉시 보안 사고 가능성은 낮다. 하지만 에이전트 기반 개선으로 확장하려면 사용자 보고, 세션 로그, 도구 출력은 모두 "명령이 아닌 데이터"로 분리해야 한다.

특히 여러 줄 입력이면 첫 줄만 blockquote처럼 보이고 나머지는 일반 prompt처럼 해석될 수 있다.

### MEDIUM 2. 테스트는 구조 확인 위주다

v1.11.9 테스트는 prompt 문자열, phase bucket, CLI path 탐지, 기본 상태를 확인한다. 이 자체는 좋다.

코드 근거:

- `app/ui/DarwinForge/Tests/DarwinForgeUITests/WalkLabV119ClaudeAnalysisTests.swift:17`
- `app/ui/DarwinForge/Tests/DarwinForgeUITests/WalkLabV119ClaudeAnalysisTests.swift:106`
- `app/ui/DarwinForge/Tests/DarwinForgeUITests/WalkLabV119ClaudeAnalysisTests.swift:140`

부족한 테스트:

- fake `claude` 실행 파일로 실제 `analyze()` 성공/timeout/non-zero/empty output 검증
- 실제 JSONL fixture에서 header + samples + summary를 읽어 prompt 생성
- malformed JSONL, legacy log, missing phase 처리
- UI의 `분석 실행` 버튼 흐름
- Claude 응답을 구조화해 저장하는 검증

## 에이전트 기반 개선 시스템이 되려면 필요한 구조

### 1. `WalkSessionContextV2`를 명시적으로 저장

세션 시작 시점에 다음 값을 header와 summary에 반드시 남겨야 한다.

- `walkingEngine`
- `algorithmMode`
- `signConvention`
- `gainProfile`
- `pitchInputConvention`
- `correctionApplyMode`
- `enableBalanceCorrection`
- `hipPitchOffsetTrimDeg`
- `strideMm`, `sideMm`, `turnDeg`, `periodMs`, `footHeightMm`
- `robotModel`, `firmwareVersion`, `onboardPatchVersion`
- `operatorNote`, `comparisonTag`, `experimentId`

### 2. `DataQualityReport`를 summary에 포함

Claude나 auto-tuner가 권고하기 전에 다음 gate를 통과해야 한다.

| 조건 | 최소 기준 |
|---|---|
| duration | 3초 이상 |
| sample count | 60개 이상 |
| sample rate | 목표 대비 70% 이상 |
| stale ratio | `imuSampleAgeMs >= 500ms` 5% 미만 |
| duplicate IMU ratio | 30% 미만 |
| bus write failure delta | 0 권장, 증가 시 권고 금지 |
| real robot ratio | 실로봇 분석이면 `imuSource=real` 다수 |
| phase coverage | 주요 phase bucket 4개 이상 |

품질 gate 실패 시 Claude는 "모션 개선 권고"가 아니라 "데이터 재수집 권고"만 해야 한다.

### 3. Claude 응답은 markdown이 아니라 구조화해야 한다

자연어 markdown은 사람이 읽기에는 좋지만 앱이 안전하게 다루기 어렵다.

권장 schema:

```json
{
  "dataQuality": {
    "verdict": "pass|weak|fail",
    "reasons": []
  },
  "diagnosis": [
    {
      "axis": "hipPitchOffsetTrimDeg",
      "severity": "high",
      "evidence": ["session id + metric"],
      "confidence": 0.0
    }
  ],
  "nextExperiment": {
    "changeOneAxisOnly": true,
    "axis": "hipPitchOffsetTrimDeg",
    "from": 13,
    "to": 8,
    "preset": "slowWalk",
    "safety": "cradle/tether",
    "successMetric": "meanAbsPitch decreases without peakAbsRoll increase",
    "rollbackCondition": "peakAbsPitch > 20 or bus failures increase"
  },
  "forbiddenChanges": [
    "hybridBA + applyToRobot",
    "v110Experimental + applyToRobot"
  ]
}
```

### 4. Claude는 controller가 아니라 critic으로 제한

실로봇에서는 Claude가 직접 모터 보정값을 바꾸면 안 된다. 역할은 다음으로 제한하는 것이 맞다.

- 데이터 품질 평가
- 원인 후보 순위화
- 한 번에 한 축만 바꾸는 다음 실험 제안
- 위험 조합 차단 재확인
- 사람이 승인할 수 있는 diff/설정 변경안 생성

실제 적용은 deterministic safety layer와 사용자 승인 뒤에만 해야 한다.

### 5. 비교 실험 단위를 만들어야 한다

에이전트가 개선하려면 "전보다 나아졌는가"를 비교할 기준이 있어야 한다.

필요 기능:

- A/B experiment id
- baseline session 고정
- 한 실험에서 한 축만 변경
- 동일 preset/동일 바닥/동일 배터리 조건 기록
- success metric 자동 계산
- 실패 시 이전 safe config로 rollback

## 우선순위 작업 제안

### P0

1. `WalkSessionHeader`/`WalkSessionSummary`에 `walkingEngine`, `pitchInputConvention`, `hipPitchOffsetTrimDeg`, tuning 파라미터, data quality report를 추가한다.
2. Claude prompt에 실제 세션별 axis 값을 출력한다.
3. data quality gate 실패 시 Claude 분석 요청 자체를 "데이터 재수집 모드"로 바꾼다.
4. Claude 응답을 markdown-only가 아니라 JSON schema로 받는다.

### P1

1. `phaseStats`에 candidate/applied를 분리해서 출력한다.
2. sagittal 분석 지표를 추가한다: pitch trend, anklePitch/hipPitch/knee delta, foot height, stride/period 대비 pitch peak.
3. `WalkLabSession` Claude path와 `WalkDataView` Claude path를 하나로 합친다.
4. fake `claude` executable 기반 integration test를 추가한다.

### P2

1. UI에 "외부 Claude CLI로 데이터가 전송됨"을 명확히 표시한다.
2. CLI 로그인/설치 상태를 분석 실행 전에 점검한다.
3. 결과를 세션 옆에 저장해 나중에 비교할 수 있게 한다.
4. markdown 패널은 유지하되, 사용자에게는 data quality와 next experiment를 먼저 보여준다.

## 최종 판정

Claude의 v1.11.9 보고는 "기능이 생겼다"는 점에서는 맞다. 하지만 "로봇을 에이전트 기반으로 모션 개선해 나갈 수 있는 퀄리티"라고 보기에는 아직 이르다.

현재 상태에서 안전하게 할 수 있는 일:

- 최근 세션을 사람이 읽기 쉬운 형태로 요약
- Claude에게 원인 후보를 물어보는 보조 분석
- 사용자의 자연어 보고를 데이터와 함께 보는 post-mortem

현재 상태에서 하면 안 되는 일:

- Claude 답변을 근거로 자동 튜닝 적용
- 실로봇에서 여러 축을 동시에 변경
- data quality가 낮은 세션으로 알고리즘 성능 결론 내리기
- markdown 답변만 보고 "원인 확정" 처리하기

따라서 이 PR은 merge 가능성을 보려면 "분석 보조 기능"으로 범위를 낮춰야 한다. "에이전트 기반 보행 개선"으로 선언하려면 P0 작업이 먼저 필요하다.

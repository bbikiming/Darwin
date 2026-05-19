# DarwinForge WalkLab — 실 ROBOTIS DARwIn-OP E2E 검증 가이드

작성일: 2026-05-19 (v1.11.14.7 기준)
대상: DarwinForge WalkLab 의 폐루프 (critic → 승인 → 보행 → 자동 비교 → rollback) 를 실 robot 에서 검증하려는 운영자.

---

## 1. 사전 준비

### 1.1 Mac 측

- DarwinForge 최신 빌드 (PR #37 머지 후): `swift build` → `swift run DarwinForgeApp`
- Claude CLI 설치 + 인증: `claude --version` 확인 (critic 분석에 필요)
- 충분한 디스크 공간 (sessions/analyses 디렉토리)

### 1.2 Robot 측

- ROBOTIS DARwIn-OP2 펌웨어 + WalkLab brokerage patch 적용:
  - `firmware-patches/walklab-brokerage/INTEGRATION.md` 참조
  - 핵심: `WalkLabBrokerage.cpp/h` + `main.cpp.patch` + `Makefile.patch`
  - 적용 후 robot 측에서 `walklab-brokerage` 데몬 실행
- SSH 키 등록 (Mac → robot 무비번 접속)
- Cradle (안전 거치대) 또는 tether (낙상 보호)

### 1.3 Network

- Mac 과 robot 이 같은 LAN (또는 robot 의 hot-spot 연결)
- robot IP 가 ConnectionStore 에 등록 (자동 검색 or 수동)

---

## 2. 검증 시나리오 (권장 순서)

### Phase 1: 데이터 진단 도구 검증

목표: critic 응답 → A/B 비교 → 자동 rollback 까지 흐름이 의도대로 동작하는지 확인.

#### 1.1 Baseline 세션 수집

1. WalkLab 진입 → 보행 엔진을 `.macSparseKeyframe` 으로 (default)
2. preset = `slowWalk` 또는 `march`
3. cradle confirmed 체크 + walking 시작
4. **5초 이상** 보행 후 stop (sample 100건 이상 권장)
5. 보행 데이터 메뉴 → 새 session 이 list 에 표시되는지 확인

#### 1.2 Critic 분석 요청

1. 보행 데이터 메뉴 → "Critic V2 (typed)" 패널 열기
2. baseline session 선택 → "분석 요청"
3. Claude critic 응답 (~10초) 확인:
   - `dataQuality.verdict` (pass/weak/fail)
   - `diagnosis` 1~2 건
   - `nextExperiment.axis` + `from`/`to`
   - `recommendation.action`

#### 1.3 ExperimentApprovalUI 검증

1. Critic 응답 후 "실험 시작" 버튼 → ApprovalUI sheet 등장
2. 확인 항목:
   - **axis 변경 미리보기**: 예) `gainProfile: v110Experimental → robotisOriginal`
   - **safetyVerdict**: safe / caution / blocked 색상
   - **validationResult banner** (issue 있을 때만 빨강)
   - **advanced 자동 활성 banner** (tuning slider axis 권고 시)
   - **walkingEngine 보행 중 reject banner** (보행 중일 때만)
3. 만약 issue banner 빨강 → "실험 시작" 버튼 자동 비활성 확인

#### 1.4 실험 적용 + Active Banner

1. issue 없으면 "실험 시작" 클릭
2. WalkLab 하단 우측에 **ActiveExperimentBanner** 표시 확인:
   - 현재 experimentId
   - lastComparison (있으면)
   - Rollback / 수락 (완료) 버튼
3. WalkLab 의 config 가 critic 의 권고대로 변경됐는지 확인 (예: gainProfile)

#### 1.5 Experiment 보행 + 자동 A/B 비교

1. 같은 preset 으로 실험 보행 1회 (5초+)
2. session end 시 lastRobotEvent 에 `🔬 A/B 비교: <verdict>` 표시 확인
3. ActiveExperimentBanner 의 verdict row 갱신 확인

#### 1.6 Rollback (CRIT 흐름)

**자동 rollback 검증**:
1. 일부러 fail 조건 유도 (예: critic 이 blocked combo 권고 시 ApprovalUI 가 reject)
2. 또는 실 보행에서 peakAbsPitch +12° 시뮬 (불가하면 mock test 로 확인)
3. lastRobotEvent 에 `🔄 자동 rollback — <reason>` 표시 확인
4. WalkLab 의 config 가 변경 전 값으로 복원됐는지 확인

**명시 rollback 검증**:
1. ActiveExperimentBanner 의 "Rollback" 버튼 클릭
2. 보행 중이었으면 자동 stop + walkReady 복귀 확인
3. config 복원 확인
4. ActiveExperimentBanner 사라짐 확인 (activeExperimentId = nil)

---

### Phase 2: ROBOTIS Onboard 모드 검증 (별도 PR — v1.11.16+)

⚠️ 본 단계는 firmware-patches/walklab-brokerage 적용 후만 가능.

#### 2.1 Onboard health check

1. WalkLab → walkingEngine picker → `.robotisOnboard` 선택
2. preset 선택 + 보행 시작
3. lastRobotEvent 확인:
   - 정상: `▶ ROBOTIS Onboard 모드: <preset> — Mac sparse 우회, 자동 명령 송출 활성`
   - 경고: `⚠️ ROBOTIS Onboard 시작 (health 경고): <warnings>`
4. 경고 내용 (있을 시):
   - `실 robot SSH 미연결` — store.bus 가 nil
   - `autoOnboardBrokering=OFF` — 수동 송출 모드
   - `cradle 미확인` — 안전 절차 위반

#### 2.2 ROBOTIS onboard 보행 실측

1. cradle 위에서 시작 (낙상 방지)
2. 실 robot 이 ROBOTIS Walking module 로 보행하는지 시각 확인
3. 비교: Mac sparse keyframe (뒤뚱거림) vs onboard (ball tracking demo 같은 안정성)

---

## 3. 주요 안전 절차

| 시점 | 확인 사항 |
|---|---|
| 보행 시작 전 | cradle confirmed = true |
| critic 권고 검토 | safetyVerdict ≠ blocked, validationResult.passed |
| 실 robot 첫 적용 | tether 또는 cradle 위 |
| 자동 rollback 동작 | failRollback verdict 시 즉시 stop + 복원 |
| 이상 진동 / fall 임박 | ⌘⇧. (Emergency Stop) — 모터 토크 OFF |

---

## 4. 알려진 한계 (v1.11.14.7 기준)

### 4.1 Mac sparse 6-phase keyframe 본질
- 80~160ms setPosition 송출 주기로 합성 → 뒤뚱거림 불가피
- ROBOTIS onboard walking (125Hz 실시간 IK + balance) 로 가야 본격 안정
- 별도 PR (v1.11.16+) 통합 작업 필요

### 4.2 실 robot E2E 자동 검증 부재
- 모든 unit test (547건) 은 mock 데이터 + 임시 디렉토리 IO
- 실 SSH brokering 의 latency / robust 검증은 사용자가 수동

### 4.3 verdict 임계값
- v1.11.14.7 에서 `ExperimentThresholds` 로 외부화 — UI 노출은 후속 PR
- 환경별 (tile 바닥 vs 카펫 등) 임계값 조정은 UserDefaults 직접 편집 또는 코드 수정

---

## 5. 트러블슈팅

### Critic 응답이 안 옴
- `claude --version` 확인. CLI 미설치 / 미인증?
- 응답 시간 ~10초 — 더 오래 걸리면 prompt 길이 또는 네트워크 문제
- `~/.claude` 로그 확인

### "실험 시작" 버튼 비활성
- ApprovalUI 의 validationIssuesBanner 확인 — issue 있으면 disable
- safetyVerdict.blocked 도 disable 트리거
- 또는 critic 응답에 `nextExperiment: null` (quality.fail) → 정상 동작

### 자동 폐루프 verdict 표시 안 됨
- 같은 experimentId 를 가진 실험 session 이 디스크에 있는지 확인 (jsonl header)
- WalkLabSession.activeExperimentId 가 보행 시작 전 set 되었는지 확인
- baseline session 의 summary.json 이 디스크에 있는지 확인

### Rollback 후 다음 실험 시도 시 reject
- v1.11.14.6+ 이상에서 fix 됨. rollbackExperiment 가 controller.cancel 호출.
- 만약 여전히 reject 면 controller.current 가 nil 인지 확인 (이전 버전 잔존?)

---

## 6. 권장 검증 sequence (1시간 분량)

1. **5분**: 사전 준비 (robot 연결, cradle 거치)
2. **10분**: Phase 1.1~1.2 baseline + critic 분석
3. **15분**: Phase 1.3~1.5 ApprovalUI + 실험 적용 + 자동 비교
4. **10분**: Phase 1.6 자동 rollback + 명시 rollback
5. **20분**: Phase 2 ROBOTIS Onboard (별도 PR 적용 시)

---

## 7. 결과 기록 양식 (사용자 권장)

| 시각 | 검증 항목 | 통과/실패 | 비고 |
|---|---|---|---|
| 11:00 | baseline 세션 수집 (slowWalk 6초) | 통과 | sample 122건, dataQuality.pass |
| 11:05 | critic 분석 → nextExperiment.gainProfile | 통과 | from v110Experimental, to robotisOriginal |
| 11:10 | ApprovalUI 표시 + safetyVerdict.safe | 통과 | issue 없음 |
| 11:15 | 실험 적용 → ActiveBanner 표시 | 통과 | gainProfile 변경 확인 |
| ... | ... | ... | ... |

이 양식으로 1회 운영 검증 완료 후 PR #37 의 comment 에 첨부 권장.

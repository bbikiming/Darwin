# SSH 연결·조종 로깅 하네스

> **목적**: SSH로 로봇을 조종한 내용과 연결 상태를 로컬에 상세히 남겨 → 사후에
> 이슈를 짚고 → 계측을 지속적으로 늘려가는 **엔지니어링 하네스**.
>
> 최종 수정: 2026-06-02

## 비유

블랙박스(주행 기록계)다. 사고가 나야 켜는 게 아니라 **항상 돌면서** 속도·제동·조향을
초 단위로 남긴다. 나중에 "왜 그때 반응이 느렸지?"를 추측이 아니라 **로그로** 답한다.
이 문서는 그 블랙박스가 (1) 무엇을 어디에 남기고 (2) 어떻게 읽고 (3) 어떻게 채널을
늘려가는지를 설명한다.

---

## 1. 결론 먼저 — 한눈에

| 질문 | 답 |
|------|----|
| 로그 어디에? | `~/Library/Application Support/DarwinForge/Harness/` (JSON Lines) |
| SSH 조종이 남나? | 예 — 매 명령마다 `remote.command_sent/responded/error` (category·지연·exit code·실패 원인) |
| 연결 상태가 남나? | 예 — `connection.attempt/success/failure/reconnect_*`, `remote.channel_changed` |
| 이슈 어떻게 봄? | 앱 내 **Harness Inspector → 세션 → Export Markdown** → "SSH 연결·조종 진단" 섹션 |
| 새 계측 어떻게 추가? | [§5 업그레이드 레시피](#5-업그레이드-레시피-지속-개선-루프) — 4단계 |

---

## 2. 무엇이 어디에 남나

### 디스크 경로

```
~/Library/Application Support/DarwinForge/Harness/
├── current-<UUID>/        # 실행 중 세션
│   ├── events.jsonl       # 이벤트 한 줄 = 한 JSON
│   ├── events.1.jsonl     # 50MB 초과 시 로테이션
│   └── meta.json          # 세션 메타(앱 버전, OS, 카운터)
└── sessions/<UUID>/       # 종료된 세션 (최근 30개 / 500MB 보존)
```

- **형식**: JSON Lines — `jq` / Python / 앱 Inspector 무엇으로든 읽힌다.
- **보존**: 세션 30개 또는 누적 500MB 초과 시 오래된 것부터 정리(`TelemetryStore.enforceRetention`).
- **연결 게이트**: 미연결(idle) 상태에선 `app`/`connection`/`harness`/`user`/`error`
  네임스페이스만 기록 — 디스크/CPU 부담 0. SSH 조종은 연결 상태에서만 일어나므로
  `remote.*`는 자연히 연결 중에만 쌓인다.

### SSH/연결 이벤트 스키마

코드 정의: [`Connection/SSHDiagnostics.swift`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/SSHDiagnostics.swift)
(payload 빌더), [`Connection/RemoteShell.swift`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/RemoteShell.swift)
(발화 지점).

#### `remote.command_sent` (actor=user) — 명령 송신
| 필드 | 의미 |
|------|------|
| `channel` | `ssh` / `unavailable` / `unknown` |
| `cmd_len` | 명령 길이 |
| `cmd_hash` | FNV-1a 해시 — 동일 명령 반복 그루핑 |
| `category` | **무엇을 조종했나**: `walk`/`stop`/`telemetry`/`demo`/`vision`/`bridge`/`head`/`motion`/`setup`/`service`/`query`/`other` |
| `preview` | 민감정보 마스킹 + 160자 절삭 명령 프리뷰 ("상세 내용") |

#### `remote.command_responded` (actor=system) — 응답 수신
| 필드 | 의미 |
|------|------|
| `elapsed_ms` | **왕복 지연** — 반응 속도 진단의 핵심 |
| `exit_code` | 로봇 측 명령 종료 코드 |
| `ok` | `exit_code == 0` — **로봇이 명령을 수락했나** (false면 거부/실패) |
| `result_len`, `cmd_hash`, `category`, `channel` | 상동 |

> ⚠️ `ok=false`(비-0 exit)는 종전엔 "응답 성공"으로만 기록돼 **로봇이 명령을 거부한
> 사실이 숨겨졌다**. 이제 `level=.warn` + `ok=false`로 드러난다.

#### `remote.command_error` (actor=system, level=warn) — 실행 실패
| 필드 | 의미 |
|------|------|
| `error_case` | **왜 실패했나**: `timeout` / `key_auth_required` / `spawn_failed` / `generic` |
| `elapsed_ms` | 실패까지 걸린 시간 — `timeout`이면 ≈4000ms(ServerAlive 2×2) |
| `multiplex` | ControlMaster 소켓 재사용 여부 |
| `category`, `cmd_hash`, `channel` | 상동 |

#### 연결 라이프사이클 (별도, 기존)
`connection.attempt` / `connection.success`(rtt_ms) / `connection.failure` /
`connection.reconnect_start` / `connection.reconnect_attempt` / `connection.disconnect` /
`remote.channel_changed`(ssh ↔ unavailable).

---

## 3. 어떻게 읽나 — 이슈 파악

### 앱 안에서 (권장)
1. **Harness Inspector** 열기 → 세션 선택.
2. **Export Markdown** → 생성된 리포트의 **"SSH 연결·조종 진단"** 섹션 확인.

이 섹션이 자동으로 계산하는 것(코드: [`SSHConnectionDiagnostics.swift`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Logging/Harness/SSHConnectionDiagnostics.swift)):

- **명령 성공률** = `ok` 응답 / (응답 + 실패). 비-0 exit는 성공에서 제외.
- **왕복 지연** p50 / p95 / max / mean — "조종 반응이 느렸나" 정량화.
- **실패 원인별 분해** — `timeout` 폭주? `key_auth_required`?
- **무엇을 조종했나** — 카테고리별 송신 횟수.
- **가장 느리거나 실패한 명령 Top N** — seq·시각·지연·결과로 drill-down.

### 명령줄에서 (raw)
```bash
DIR=~/Library/Application\ Support/DarwinForge/Harness
# 가장 최근 세션의 SSH 실패 원인 집계
cat "$DIR"/sessions/*/events.jsonl \
  | jq -r 'select(.k=="remote.command_error") | .d.error_case' \
  | sort | uniq -c | sort -rn

# 왕복 지연 p95 (responded)
cat "$DIR"/sessions/*/events.jsonl \
  | jq 'select(.k=="remote.command_responded") | .d.elapsed_ms' \
  | sort -n | awk '{a[NR]=$1} END{print a[int(NR*0.95)]}'
```
> 외부 분석 상세: [`analyzing-logs-externally.md`](analyzing-logs-externally.md).

---

## 4. 알려진 장애 패턴과 로그 시그니처

| 증상 | 로그 시그니처 | 해석 / 조치 |
|------|--------------|-------------|
| 조종 반응이 느림 | `command_responded.elapsed_ms` p95 ↑ (수백 ms+) | WiFi RTT/혼잡. ControlMaster(`multiplex=true`) 확인, 5GHz 사용 |
| 가끔 끊김/멈춤 | `command_error.error_case=timeout` 산발 + `elapsed_ms≈4000` | WiFi stall. ServerAlive가 4s에 abort 중. AP 거리/간섭 점검 |
| 명령 먹통(초기) | `command_error.error_case=key_auth_required` 연속 | SSH 키 미셋업 → `ssh-copy-id -i ~/.ssh/id_rsa_darwin.pub robotis@<ip>` 1회 |
| 보냈는데 안 움직임 | `command_responded.ok=false` (`level=.warn`) | 로봇이 명령 거부(비-0 exit). 데몬 미기동/모드 불일치 |
| 채널 깜빡임 | `remote.channel_changed` 빈발 | SSH 도달성 요동. 전원/LAN/WiFi 안정성 |
| 연결 자체 실패 | `connection.failure` 반복, `reconnect_attempt` 누적 | 엔드포인트/전원. `connection.success.rtt_ms`로 회복 확인 |

`HarnessInsights`의 `remote.command_error_pattern` 규칙은 세션 중 `remote.command_error`가
3회 이상이면 자동 인사이트를 띄운다(코드: `HarnessInsightsPilotClaude.swift`).

---

## 5. 업그레이드 레시피 (지속 개선 루프)

새로운 신호를 남기고 싶을 때 따르는 **4단계**. 핵심 원칙: payload는 **순수 함수**로
빌드해 테스트로 못 박고, 분석기·문서·테스트를 함께 갱신한다.

### 단계 1 — 무엇을 남길지 정의
- 기존 이벤트에 **필드 추가**면 → 빌더만 수정(아래 2).
- 새로운 **종류**면 → `TelemetryEvent.swift`에 `TelemetryKind` 상수 추가
  (`namespace.event`, snake_case). 네임스페이스가 `connection`/`app`/`harness`/`user`/`error`가
  아니면 **연결 중에만** 기록됨에 유의([`Harness.shouldRecord`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Logging/Harness/Harness.swift)).

### 단계 2 — payload를 순수 함수로
`SSHDiagnostics.swift`에 빌더 추가/확장. 예:
```swift
public static func respondedData(command:channel:exitCode:elapsedMs:resultLen:) -> [String: AnyCodable]
```
민감정보는 `redactedPreview` 패턴으로 마스킹. 원문 전체는 절대 그대로 남기지 않는다.

### 단계 3 — 발화 지점에서 호출
`RemoteShell.send`(또는 해당 lifecycle 지점)에서 `harness.record(.kind, data: SSHDiagnostics.xxxData(...))`.
**send 자체엔 로직을 두지 말 것** — payload 구성은 전부 순수 함수로(테스트 가능성).

### 단계 4 — 분석기 + 문서 + 테스트
- `SSHConnectionDiagnostics.analyze`에 집계 추가 → `markdown`에 표 한 줄.
- 본 문서 §2 스키마 표 + §4 패턴 표 갱신.
- 테스트:
  - 빌더/분류 → `SSHDiagnosticsTests.swift`
  - 분석기 → `SSHConnectionDiagnosticsTests.swift` (실 payload 빌더로 이벤트 생성 → 필드명 drift 차단)

### 회귀 가드
- payload 필드 이름은 분석기·문서·외부 jq 쿼리가 의존하는 **계약**이다. 바꾸면 셋 다 갱신.
- `error_case` 값은 추가는 안전(소비처 `remote.command_error_pattern`은 개수만 셈), 기존 값
  rename은 외부 대시보드/쿼리를 깬다.

---

## 관련 코드·문서
- 스키마: [`TelemetryEvent.swift`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Logging/Harness/TelemetryEvent.swift)
- 파사드/기록: [`Harness.swift`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Logging/Harness/Harness.swift), [`TelemetryRecorder.swift`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Logging/Harness/TelemetryRecorder.swift)
- 범용 분석: [`SessionAnalysis.swift`](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Logging/Harness/SessionAnalysis.swift)
- 하네스 개요: [`telemetry-harness.md`](telemetry-harness.md) · [`engineering-foundations.md`](engineering-foundations.md)

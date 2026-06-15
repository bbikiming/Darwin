# Harness 로그를 Claude Code / Codex 로 분석하기

> 텔레메트리 하네스 v1.14.2 로 디스크에 쌓인 로그를 외부 AI 도구가 그대로 읽고 분석할 수 있게 설계됨. 본 문서는 **사용자가 던질 수 있는 prompt 템플릿 + 표준 jq query + export 흐름**.

---

## 1. 로그 저장 위치 (확정)

```
~/Library/Application Support/DarwinForge/Harness/
├── current-<UUID>/                     # 진행 중 세션 (앱 실행 중)
│   ├── events.jsonl                    # 한 줄당 한 이벤트
│   └── meta.json                       # 카운터/시각/버전
└── sessions/                           # 종료된 세션
    ├── <UUID>/                         # 30개 retention, 500 MB cap
    │   ├── events.jsonl
    │   ├── meta.json
    │   └── events.1.jsonl              # 50 MB 초과 시 rotation
    └── ...
```

Finder 에서 열기:
```bash
open "$HOME/Library/Application Support/DarwinForge/Harness"
```

---

## 2. 외부 도구 호환성 (검증 완료)

| 도구 | 작업 | 결과 |
|------|------|------|
| `cat` | meta.json 직접 읽기 | ✅ pretty-printed |
| `head`/`tail` | events.jsonl line scan | ✅ 표준 |
| `jq` | JSON 필드 추출 | ✅ 한 줄당 valid JSON |
| `grep` | 키워드 / level 필터 | ✅ 평문 |
| Claude Code (`Read` tool) | 파일 직접 읽기 | ✅ 텍스트 |
| Codex (`exec` 모드) | repo 안 파일 / `~/Library/` 외부 경로 — sandbox 영향 받을 수 있음. ZIP/JSON export 권장 | ✅ export 후 |
| Python / pandas | JSONL → DataFrame | ✅ `pd.read_json(... lines=True)` |

---

## 3. Quick reference — Claude Code 에 던질 한 줄 prompts

세션 디렉토리 경로를 자기 머신 기준으로 치환하여 사용. ID8 (앞 8자) 알면 `scripts/harness-manifest.sh` 로 전체 경로 빠르게 확보.

### 3.1 가장 빠른 진단 (어제 뭐가 잘못됐는지)

```
/Users/bbikiming/Library/Application\ Support/DarwinForge/Harness/sessions/<UUID>/events.jsonl
를 읽고 다음을 답해줘:
1. 세션 길이 + 주요 이벤트 흐름 (3-5 줄 요약)
2. error / warn 레벨 이벤트의 직전 5건 컨텍스트
3. 가장 가능성 높은 근본 원인 1-2개
4. 다음 시도 시 확인해야 할 점 3가지

context (모든 이벤트의 c 필드): cn=connection state, ep=endpoint (redacted),
sc=section, bv=battery V, rt=RTT ms, im=imu stale flag.
짧은 key 의미: i=seq, k=kind (namespace.event), lv=level, a=actor, d=payload, tw=wall clock.
```

### 3.2 세션 비교 ("어제는 됐는데 오늘은 안 됨")

```
세션 A: /Users/.../sessions/<UUID-A>/
세션 B: /Users/.../sessions/<UUID-B>/

두 세션의 meta.json + events.jsonl 을 비교해서:
1. metric 차이 (RTT / 배터리 / 연결 성공률 / 에러 카운트)
2. B 에만 새로 등장한 이벤트 kind
3. A 에서 성공했던 흐름이 B 에서 어디까지 진행되다 막혔는지
4. 회귀 가능성 있는 코드 영역 추정 (kind namespace 기준)
```

### 3.3 JSON Report (이미 분석된 형태)

앱 안 Inspector → 세션 선택 → "JSON" 버튼 → 저장. 이 파일을 직접 첨부:

```
이 harness session JSON report 를 분석해줘:
- session block 의 duration / event count
- summary 의 connection / bus / imu / walklab 통계
- insights[] 의 권고 사항 우선순위 정렬
- errors[] envelope 의 가장 위험한 trigger 1-2개

format spec: schema "darwinforge-harness/1.0" (docs/harness/log-utilization-system.md §5).
```

### 3.4 manifest 기반 세션 선택

```bash
scripts/harness-manifest.sh --errors    # error_count > 0 만 보고
```
또는
```
scripts/harness-manifest.sh --json 출력을 보고 다음을 알려줘:
1. errorCount > 0 인 세션 중 가장 최근 3개
2. 각 세션의 ID8 + 시각 + 에러 수
3. 어떤 세션을 먼저 자세히 봐야 할지 (우선순위)
```

---

## 4. 표준 jq query 모음 (Claude 가 받아서 그대로 실행 가능)

세션 디렉토리를 `$S` 로 지정:
```bash
S="$HOME/Library/Application Support/DarwinForge/Harness/sessions/<UUID>"
```

### 4.1 에러 / 경고만 추출
```bash
jq -c 'select(.lv == "error" or .lv == "warn")' "$S/events.jsonl"
```

### 4.2 특정 namespace 이벤트 흐름
```bash
jq -c 'select(.k | startswith("walklab"))' "$S/events.jsonl"
jq -c 'select(.k | startswith("connection"))' "$S/events.jsonl"
jq -c 'select(.k | startswith("bus"))' "$S/events.jsonl"
```

### 4.3 컨텍스트 변화 시계열 (RTT / 배터리)
```bash
jq -r '[.tw, .c.rt // "-", .c.bv // "-", .c.cn] | @tsv' "$S/events.jsonl" \
  | grep -v "^-" | head -30
```

### 4.4 e-stop 직전 5개 이벤트 (envelope)
```bash
# 가장 오래된 e-stop 찾기
SEQ=$(jq -r 'select(.k == "bus.e_stop" or .k == "walklab.emergency_stop") | .i' "$S/events.jsonl" | head -1)
# ± 5 컨텍스트
jq -c "select(.i >= $((SEQ-5)) and .i <= $((SEQ+5)))" "$S/events.jsonl"
```

### 4.5 walklab 시작-종료 페어
```bash
jq -c 'select(.k == "walklab.start" or .k == "walklab.stop" or .k == "walklab.emergency_stop") | {seq: .i, k, tw, preset: .d.preset}' "$S/events.jsonl"
```

### 4.6 namespace 별 카운트
```bash
jq -r '.k | split(".")[0]' "$S/events.jsonl" | sort | uniq -c | sort -rn
```

### 4.7 사용자 액션 만 (actor=user)
```bash
jq -c 'select(.a == "user") | {seq: .i, kind: .k, payload: .d}' "$S/events.jsonl"
```

---

## 5. ZIP / JSON 으로 export 해서 다른 PC / 외부 도구로 보내기

Inspector 에서:
- **ZIP** — 디렉토리 전체 (events.jsonl + rotation + meta.json) 압축
- **Markdown 리포트** — 사람이 읽기 좋은 요약 + envelopes
- **JSON 리포트** — `darwinforge-harness/1.0` schema, Claude API/Codex 친화

CLI 로 직접:
```bash
S="$HOME/Library/Application Support/DarwinForge/Harness/sessions/<UUID>"
cd "$(dirname "$S")" && zip -r ~/Downloads/harness-$(basename "$S" | cut -c1-8).zip "$(basename "$S")"
```

---

## 6. PII / 보안 — 외부 도구로 보낼 때 안심해도 되는 이유

다음은 디스크에 들어가지 않거나 redact 됨:
- **endpoint** — IPv4/IPv6 마지막 옥텟 마스크, USB serial suffix 제거 (`usb:tty.usb-X`)
- **에러 메시지** — 본문 X, `error_len` + `error_hash` (FNV-1a 32bit) 만
- **사용자 자유 텍스트** (북마크 / 페이지 이름 / 자세 이름) — 길이 + hash
- **Claude 프롬프트 본문** — `text_length` + `turn` 만, 본문 X
- **JSON Export 의 errors[].payload** — allow-list 기반 `scrubPayload()` 통과 → 모르는 키는 자동 `_len/_hash`

따라서 외부 LLM 에 jsonl/json/zip 그대로 첨부해도 사용자 PII 가 노출되지 않음.

---

## 7. 표준 prompt 템플릿 (그대로 복붙)

### 7.1 단일 세션 진단

```
[Harness 세션 분석 요청]

세션 경로:
~/Library/Application Support/DarwinForge/Harness/sessions/<UUID>/

events.jsonl 의 모든 이벤트를 읽고 다음 순서로 답해줘:

1. **세션 요약 (3줄)** — 시작 시각, 종료 시각, 주요 활동 namespace.
2. **에러/경고 envelopes** — 각 trigger 의 직전/직후 컨텍스트 (±5 events).
3. **근본 원인 후보** — 가장 가능성 높은 1-3개, 증거 (event seq) 제시.
4. **다음 시도 권고** — 사용자가 무엇을 바꿔야 할지 구체적으로.

이벤트 schema:
- i (seq), k (namespace.event), lv (trace|info|notice|warn|error)
- a (user|system|robot|claude), tw (wall ISO), d (payload), c (context)
- c.cn = 연결상태, c.ep = endpoint, c.sc = section, c.bv = battery V,
  c.rt = RTT ms, c.im = imu stale flag
```

### 7.2 세션 회귀 진단 (A vs B)

```
[Harness 두 세션 비교]

baseline (잘 됐던): ~/.../sessions/<UUID-A>/
current (망가진):  ~/.../sessions/<UUID-B>/

각 세션의 meta.json + events.jsonl 을 비교해서:

1. **메트릭 차이** — RTT (mean/p95), 에러 카운트, 연결 성공률, e-stop.
2. **B 에만 등장한 이벤트 kind** — 회귀 신호.
3. **A 의 성공 흐름 vs B 의 막힌 지점** — 어디까지 같이 가다 갈라졌나.
4. **코드 영역 추정** — kind namespace 기준 (`walklab.*` 면 WalkLabSession,
   `bus.*` 면 ConnectionStore + bus driver 등).
```

### 7.3 Codex 에 던질 형태 (read-only sandbox)

ZIP 으로 export 한 뒤 repo 안 적당한 위치에 두고:
```bash
mkdir -p tmp/harness-analysis
cp ~/Downloads/harness-XXXX.zip tmp/harness-analysis/
unzip tmp/harness-analysis/harness-XXXX.zip -d tmp/harness-analysis/

# Codex 에 prompt:
# "tmp/harness-analysis/<UUID>/events.jsonl 을 읽고 위 7.1 템플릿을 그대로 따라줘."
```

---

## 8. 향후 — CLI 자동화

추후 다음을 고려:
- `scripts/harness-analyze.sh <ID8>` — 자동으로 SessionAnalysis 통계 + insights 출력 (Swift CLI 래퍼).
- `scripts/harness-tail.sh` — current 세션 live tail (`tail -f events.jsonl | jq`).
- `~/.gitignore.global` 에 `harness-*.zip` 추가 권장 (실수 commit 방지).

---

**참고**:
- `docs/harness/telemetry-harness.md` — 기록 레이어 (v1.12)
- `docs/harness/real-robot-verification.md` — 실 로봇 검증 가이드 (v1.13)
- `docs/harness/log-utilization-system.md` — 활용 시스템 (v1.14)
- 본 문서 — 외부 도구 분석 가이드 (v1.14.2)

# Sprint 9 / 10 / 12 통합 보고서 — Motion Synthesis Engine

> **기간**: 2026-05-12
> **PRD**: [PRD-001 motion-synthesis-v1.md](../prd/motion-synthesis-v1.md)
> **ADR**: [ADR-014 motion-synthesis.md](../decisions/ADR-014-motion-synthesis.md)
> **상태**: Sprint 9 + 10 + 12 ✅ 완료. Sprint 11 (SwiftUI Synth Palette) PENDING.

## TL;DR

**기존 ROBOTIS-OP2 motion_4096.bin 의 16 카탈로그 페이지를 reference 로 새 모션
페이지를 알고리즘적으로 합성하는 엔진을 본구현하고 Claude Code 와 통합했다.**

- **Rust workspace tests**: 73 → 302 (+229)
- **신규 crate**: 1 (`forge-mcp-synth`)
- **forge-core 신규 모듈**: 17 (`synth/*`)
- **MCP tools**: 11
- **CLI 서브명령**: 1 (`forge synth ...` with 11 sub-actions)
- **Slash command**: 1 (`/synth`)
- **Subagent**: 1 (`motion-composer`)
- **신규 문서**: PRD-001, ADR-014, page-catalog-motion4096.md, page-metadata-motion4096.toml

## Sprint 9 — Synthesis Core (S9-1 ~ S9-12)

### 6 합성 연산자

모든 연산자는 `SynthOp` trait 의 순수 함수 인터페이스. 입력 페이지는 borrow only.

| 연산자 | 의도 | Ground Truth |
|--------|------|--------------|
| `Sequence` | 페이지 시간순 연결 + bridge step | 7 step 초과 시 자동 chain |
| `Layer` | 부위별 (상체/하체/머리) 동시 합성 | priority + fallback 정책 |
| `Morph` | 두 페이지 가중 평균 | constant α 또는 smoothstep |
| `Mutate` | 단일 페이지 변형 (5 종) | time_scale, speed_scale, amplitude, repeat, joint_offset |
| `Mirror` | 좌·우 반전 | **page 12 ↔ page 13 (mean abs diff < 600 raw)** |
| `Procedural` | 궤적 함수 (linear / ease / sine / bezier) | anchor 사이 step 수학적 생성 |

### Mirror 운동학 분석

페어별 mode 자동 결정 — `page 9 walkready` 의 모터 영점 분석 기반:

| 페어 | 운동축 | R+L sum | Mode |
|------|--------|--------:|------|
| SHOULDER_PITCH (1-2) | sagittal | 4016 ≈ 4095 | **Swap + Reflect** |
| SHOULDER_ROLL (3-4) | frontal | 4093 | Swap + Reflect |
| ELBOW (5-6) | sagittal | 4629 ≠ 4095 | **Swap only** |
| HIP_YAW (7-8) | transverse | — | Swap + Reflect |
| HIP_ROLL (9-10) | frontal | 4100 | Swap + Reflect |
| HIP_PITCH (11-12) | sagittal | 3681 ≠ 4095 | Swap only |
| KNEE (13-14) | sagittal | 5112 ≠ 4095 | Swap only |
| ANKLE_PITCH (15-16) | sagittal | — | Swap only |
| ANKLE_ROLL (17-18) | frontal | — | Swap + Reflect |
| HEAD_PAN (19) | yaw | — | Self + Reflect |
| HEAD_TILT (20) | pitch | — | Identity |

### 4-stage Validator

| Stage | 알고리즘 | 거부 정책 |
|-------|----------|-----------|
| V1 JointLimit | `JointLimits::for_joint(j).position_min/max` | Hard fail |
| V2 Velocity | `delta_raw / play_ms > 4.3` (MX-28 max 75%) | FAIL |
| V3 SelfCollision | `crate::safety::self_collision::check_page` (룰 5 종) | FAIL |
| V4 StaticStability | hip_pitch L/R diff > 1700 raw (single_foot_ok 시 skip) | FAIL |

### Test Fixtures (공식 모션 기반)

`DARwIn-OP_ROBOTIS_v1.6.0/Data/motion_4096.bin` 의 6 페이지를 hand-coded byte-preserving 으로 임베드:

```
page_1_init           (2 step, Safe)
page_2_ok             (5 step, Safe)  
page_9_walkready      (1 step, Safe)
page_12_right_kick    (7 step, HighRisk) ← Mirror ground truth
page_13_left_kick     (7 step, HighRisk) ← Mirror ground truth
page_16_stand_up      (1 step, Safe)
```

플래그 비트 (`0x4000` INVALID, `0x4200` TORQUE_OFF+INVALID) 모두 보존.

### Integration (10 scenario)

1. Stand Up → 4 stage all PASS
2. 16 catalog pages → V3 (룰 기반) all PASS (V1/V2 는 보수성 — kick/getup fail 가능)
3. HighRisk pages → `single_foot_ok=true` 시 V4 PASS
4. Mirror page 12 → 구조 무결성 + V4 PASS
5. **Sequence walkready→kick→walkready + Manifest JSON round-trip** (2-page chain)
6. Mutate slow init (TimeScale 2×) → 4 stage all PASS
7. Mirror + Sequence 조합 (HighRisk 전파)
8. **Validator failure → Mutate 회복** (V1 fail → AmplitudeScale 0 → V1 PASS)
9. byte-preserving (Mirror / Mutate / Sequence 모두 INVALID 플래그 보존)
10. Mirror involution × 16 페이지 (`mirror(mirror(x)) == x`)

## Sprint 10 — CLI & MCP

### forge-cli `synth` (11 서브명령)

```bash
forge synth library list   [--tag <t>] [--id <n>] [--safety safe|caution|highrisk]
forge synth library metadata <id>
forge synth sequence <ids...>  [--transition-ms <n>] [--base-id <n>] [--name <s>]
forge synth layer       --upper <id> --lower <id> [--head <id>]
forge synth morph       <a> <b> [--ratio <0..1>] [--progressive]
forge synth mutate      <id>   [--time-scale <k>] [--speed-scale <k>] [--repeat <n>]
                               [--amplitude <k>] [--joint-offset <id>=<delta>]+
forge synth mirror      <id>   [--new-id <n>] [--name <s>]
forge synth procedural  --anchor-start <id> --anchor-end <id>
                        --curve linear|ease|sine|bezier [--sine-omega <f>]
forge synth validate    <page.json> [--single-foot-ok]
forge synth commit      <page.json> --slot <n> [--no-backup] [--force]
forge synth simulate    <page.json> [--format ascii|summary]
```

### MCP 서버 `forge-mcp-synth`

**stdio JSON-RPC 2.0**. 외부 dep 없이 std + serde 만 사용 → Cargo.lock 충돌 회피.

```
Initialize ──► capabilities + serverInfo
tools/list ──► 11 tools schema
tools/call ──► engine.with_library(...) ──► motion JSON
```

| Tool | 입력 | 출력 |
|------|------|------|
| `library_search` | tag / safety | 페이지 목록 + 메타데이터 |
| `library_get` | page_id | Motion JSON + Metadata |
| `synth_sequence` | page_ids[], transition_ms | Motion JSON (chain 가능) |
| `synth_layer` | upper, lower, head? | Motion JSON |
| `synth_morph` | a, b, ratio | Motion JSON |
| `synth_mutate` | page_id, mutations | Motion JSON |
| `synth_mirror` | page_id | Motion JSON |
| `synth_procedural` | anchor_start, anchor_end, curve | Motion JSON |
| `validate` | motion_json | 4-stage report |
| `commit` | motion_json, slot, force? | Backup + manifest 경로 |
| `preview` | motion_json, format | ASCII timeline 또는 summary |

### 안전 게이트 검증 (sandbox)

```
$ python3 /tmp/mcp_e2e_test.py
[7] synth_mutate page 1 TimeScale 1.5  → id=100, play_time=188 (was 125)
[8] validate                            → Overall: PASS
[9] commit slot 100 (no force)          → slot 점유 거부
[12] kick mirror commit                 → V1+V2+V3 FAIL → commit 거부

$ ls /tmp/forge_sandbox/
test_motion.bin                  (131072, init_slow at slot 100)
test_motion.bin.1778541639       (자동 백업 1)
test_motion.bin.1778541665       (자동 백업 2)
test_motion.slot100.manifest.json (provenance)
```

Manifest 예시:
```json
{
  "page_id": 100,
  "page_name": "init_slow",
  "created_epoch_ms": 1778541665153,
  "engine_version": "0.1.0-skeleton",
  "operator": "mcp_commit",
  "inputs": [{"page_id":100,"page_name":"init_slow","digest":"siphash13:7a6a12b99d017910"}]
}
```

## Sprint 12 — Claude Integration

### 3-Track

| Track | 파일 | 역할 |
|-------|------|------|
| Slash command | `.claude/commands/synth.md` | `/synth <자연어>` 진입점 |
| Subagent | `.claude/agents/motion-composer.md` | opus 합성 전문 에이전트 |
| MCP server | `.claude/settings.json::mcpServers` | `cargo run -p forge-mcp-synth` 자동 spawn |

### Permission Matrix

```json
"allow": [
  "mcp__forge-motion-synth__library_*",
  "mcp__forge-motion-synth__synth_*",
  "mcp__forge-motion-synth__validate",
  "mcp__forge-motion-synth__preview",
  "Bash(cargo build/test/clippy/fmt:*)",
  "Bash(forge synth:*)"
],
"ask": [
  "mcp__forge-motion-synth__commit",   ← 사용자 확인 필수
  "Bash(rm:*)",
  "Bash(git push:*)"
],
"deny": ["Bash(rm -rf /:*)", "Bash(rm -rf ~:*)"]
```

### 안전 4-layer

1. **slash command 본문** — `commit` 자동 호출 금지
2. **subagent system prompt** — Hard Constraint (force 자동 금지, validator 우회 금지)
3. **settings.json permissions** — `commit` 도구 → `ask`
4. **MCP server 자체** — validator FAIL → commit 거부

## 부수 수정 (공식 모션 정합성)

| 위치 | 변경 | 근거 |
|------|------|------|
| `synth/library.rs::HEADER_OFFSET_*` | 5 상수 정정 | ROBOTIS `Action.h` line 41-59 |
| `synth/integration.rs::official_bin_path` | `../../research` → `../../../research` | CARGO_MANIFEST_DIR 위치 |
| `forge-cli::synth::DEFAULT_BIN_RELATIVE` | 동일 | 동일 |
| Integration test expectations | "all V1/V2 PASS" → "V3 PASS + Stand Up V1/V2 PASS" | V1/V2 보수성 인정 |

## 향후 작업

- **Sprint 11** SwiftUI Synth Palette (PENDING — GUI 작업 worktree 머지 후)
- **Validator calibration** (PRD §17.4) — V1/V2 임계를 실 robot 한계로 보정
- **실기기 dry-run** — torque OFF mode 로 합성 페이지 송출, 사용자 supervised
- **GIF preview** (S10-4 미완) — SwiftUI viewer 헤드리스 또는 별도 렌더러

## 참고

- PRD-001 [`docs/prd/motion-synthesis-v1.md`](../prd/motion-synthesis-v1.md)
- ADR-014 [`docs/decisions/ADR-014-motion-synthesis.md`](../decisions/ADR-014-motion-synthesis.md)
- 페이지 카탈로그 [`docs/motion-format/page-catalog-motion4096.md`](../motion-format/page-catalog-motion4096.md)
- 메타데이터 sidecar [`docs/motion-format/page-metadata-motion4096.toml`](../motion-format/page-metadata-motion4096.toml)
- `.claude/` README [`.claude/README.md`](../../.claude/README.md)

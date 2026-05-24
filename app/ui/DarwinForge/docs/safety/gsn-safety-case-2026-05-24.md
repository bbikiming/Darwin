# GSN Safety Case — DarwinForge 2026-05-24

> Goal Structuring Notation (GSN Community Standard v3, 2021).
> 본 문서는 STPA analysis (`stpa-analysis-2026-05-24.md`) 의 8개 UCA 를
> "Hazard-Mitigation Argument" 로 시각화한 V287-4 산출물.

| 항목 | 값 |
|---|---|
| 작성일 | 2026-05-24 (KST) |
| 사이클 | V287-4 |
| 방법론 | GSN Community Standard v3 (2021) |
| 대상 | DarwinForge macOS app + ROBOTIS-OP2 robot |
| 관련 문서 | `stpa-analysis-2026-05-24.md`, V286-1, V282-5 |

---

## 1. Top Goal (G1)

```mermaid
graph TD
    G1["G1: DarwinForge 는 교육용 휴머노이드 robot 운영에 안전하다<br/>(safe for educational humanoid robot operation)"]
    S1["S1: Hazard-Mitigation Argument<br/>STPA 8 UCA × verified mitigation"]
    C1_ctx["Context C1:<br/>운영 environment = 교실 / 연구실<br/>운영자 = 훈련된 학생 / 개발자"]
    A1["Assumption A1:<br/>ROBOTIS-OP2 hardware spec 신뢰<br/>(motor / IMU / battery)"]
    J1["Justification J1:<br/>STPA + GSN = 항공/원자력 안전 표준<br/>(Leveson 2012, GSN v3)"]

    G1 --> S1
    G1 -.-> C1_ctx
    G1 -.-> A1
    S1 -.-> J1

    classDef goal fill:#fff3cd,stroke:#d39e00,stroke-width:2px
    classDef strategy fill:#d1ecf1,stroke:#0c5460,stroke-width:2px
    classDef context fill:#e2e3e5,stroke:#6c757d,stroke-dasharray:5 5
    class G1 goal
    class S1 strategy
    class C1_ctx,A1,J1 context
```

### G1 statement

**"DarwinForge is safe for educational humanoid robot operation, within the bounds defined by ISO 13482 personal-care-robot Class B/C risk levels."**

### Strategy S1

**"Hazard-Mitigation Argument"** — STPA 에서 식별된 8개 UCA 에 대해 각각 mitigation 이 존재하고 evidence 로 검증된다는 논증.

---

## 2. Sub-Goals (G2-G9) — UCA 별

각 UCA 에 대응하는 sub-goal + evidence 노드.

### G2 — UCA-1 prevented by E-Stop SSoT chain

```mermaid
graph TD
    G2["G2: UCA-1 (emergencyStop not-provided)<br/>이 E-Stop SSoT chain 으로 방지된다"]
    E2a["Evidence E2a:<br/>V283-3 commit 34c5b22<br/>JointControlView bypass fix"]
    E2b["Evidence E2b:<br/>V282-5 critic finding C1 식별"]
    OC1["Open Claim OC1:<br/>IntentDispatcher 본체 chain 완성<br/>(다음 cycle)"]

    G2 --> E2a
    G2 --> E2b
    G2 -.->|incomplete| OC1

    classDef goal fill:#fff3cd,stroke:#d39e00
    classDef evidence fill:#d4edda,stroke:#28a745
    classDef open fill:#f8d7da,stroke:#dc3545,stroke-dasharray:5 5
    class G2 goal
    class E2a,E2b evidence
    class OC1 open
```

### G3 — UCA-2 prevented by joint limit clamp

```mermaid
graph TD
    G3["G3: UCA-2 (writeJointPosition provided-wrong)<br/>이 joint limit clamp 로 방지된다"]
    OC2["Open Claim OC2:<br/>writeJointPosition 의 per-joint min/max clamp<br/>아직 미적용 (V288 권고)"]

    G3 -.->|incomplete| OC2

    classDef goal fill:#fff3cd,stroke:#d39e00
    classDef open fill:#f8d7da,stroke:#dc3545,stroke-dasharray:5 5
    class G3 goal
    class OC2 open
```

### G4 — UCA-3 prevented by IMU freshness gate

```mermaid
graph TD
    G4["G4: UCA-3 (gait phase wrong-time)<br/>이 IMU freshness gate (200ms) 로 방지된다"]
    E4["Evidence E4:<br/>V283-2 partial — 5s threshold 도입<br/>(목표는 200ms)"]
    OC3["Open Claim OC3:<br/>200ms threshold + ZMP gate (V287-2)<br/>+ freeze 감지"]

    G4 --> E4
    G4 -.->|incomplete| OC3

    classDef goal fill:#fff3cd,stroke:#d39e00
    classDef evidence fill:#d4edda,stroke:#28a745
    classDef open fill:#f8d7da,stroke:#dc3545,stroke-dasharray:5 5
    class G4 goal
    class E4 evidence
    class OC3 open
```

### G5 — UCA-4 prevented by dxlPower gate

```mermaid
graph TD
    G5["G5: UCA-4 (writeJointPosition after OFF)<br/>이 dxlPower gate 로 방지된다"]
    E5a["Evidence E5a:<br/>V283-4 commit 0dd6f1a<br/>writeJointPosition wrapper + 8 unit tests"]
    E5b["Evidence E5b:<br/>V282-5 critic finding C2 식별"]
    OC4["Open Claim OC4:<br/>WalkCycleEngine 의 bus.setPosition<br/>→ store.writeJointPosition 교체"]

    G5 --> E5a
    G5 --> E5b
    G5 -.->|incomplete| OC4

    classDef goal fill:#fff3cd,stroke:#d39e00
    classDef evidence fill:#d4edda,stroke:#28a745
    classDef open fill:#f8d7da,stroke:#dc3545,stroke-dasharray:5 5
    class G5 goal
    class E5a,E5b evidence
    class OC4 open
```

### G6 — UCA-5 prevented by disconnect-safe-state

```mermaid
graph TD
    G6["G6: UCA-5 (dxlPower OFF on disconnect not-provided)<br/>이 disconnect → dxlPower(false) 강제로 방지된다"]
    OC5["Open Claim OC5:<br/>disconnect handler 의 자동 safe state<br/>미적용"]

    G6 -.->|incomplete| OC5

    classDef goal fill:#fff3cd,stroke:#d39e00
    classDef open fill:#f8d7da,stroke:#dc3545,stroke-dasharray:5 5
    class G6 goal
    class OC5 open
```

### G7 — UCA-6 prevented by scene preview = sim only

```mermaid
graph TD
    G7["G7: UCA-6 (scene preview provided-wrong)<br/>이 scene preview = sim only enforce 로 방지된다"]
    OC6["Open Claim OC6:<br/>scene preview API 에 simOnly assertion<br/>미적용"]

    G7 -.->|incomplete| OC6

    classDef goal fill:#fff3cd,stroke:#d39e00
    classDef open fill:#f8d7da,stroke:#dc3545,stroke-dasharray:5 5
    class G7 goal
    class OC6 open
```

### G8 — UCA-7 prevented by reconnect lock + flush

```mermaid
graph TD
    G8["G8: UCA-7 (reconnect + command wrong-time)<br/>이 reconnect lock + queue flush 로 방지된다"]
    E8["Evidence E8:<br/>recovery state machine 일부 존재<br/>(부분 mitigation)"]
    OC7["Open Claim OC7:<br/>reconnect lock + command queue flush<br/>명시적 구현 미완"]

    G8 --> E8
    G8 -.->|incomplete| OC7

    classDef goal fill:#fff3cd,stroke:#d39e00
    classDef evidence fill:#d4edda,stroke:#28a745
    classDef open fill:#f8d7da,stroke:#dc3545,stroke-dasharray:5 5
    class G8 goal
    class E8 evidence
    class OC7 open
```

### G9 — UCA-8 prevented by battery preflight block

```mermaid
graph TD
    G9["G9: UCA-8 (walking start provided-wrong)<br/>이 low battery preflight block 으로 방지된다"]
    E9["Evidence E9:<br/>V264-1 battery preflight L0 (warning)<br/>도입"]
    OC8["Open Claim OC8:<br/>L1 (block) 강제 — start API throw<br/>미적용"]

    G9 --> E9
    G9 -.->|incomplete| OC8

    classDef goal fill:#fff3cd,stroke:#d39e00
    classDef evidence fill:#d4edda,stroke:#28a745
    classDef open fill:#f8d7da,stroke:#dc3545,stroke-dasharray:5 5
    class G9 goal
    class E9 evidence
    class OC8 open
```

---

## 3. Evidence Nodes — 통합 인덱스

전체 case 에서 사용된 evidence 노드.

| Evidence ID | 출처 | 종류 | UCA 매핑 |
|---|---|---|---|
| **E-V277A** | V277-A 사이클 평가: **58/100** | overall safety score | G1 |
| **E-V281-5** | V281-5 사이클 평가: **65/100** (+7) | overall safety score | G1 |
| **E-ISO13482** | ISO 13482 self-assessment: **5/10** | external standard | G1 |
| **E-NPR7150** | NPR 7150.2D Class C: **60%** | external standard | G1 |
| **E-V286-1** | V286-1 STPA 8 UCA 식별 보고 | hazard analysis | G2-G9 |
| **E2a** | V283-3 commit `34c5b22` | code + test | G2 |
| **E2b** | V282-5 critic C1 finding | analysis | G2 |
| **E4** | V283-2 partial (5s threshold) | code | G4 |
| **E5a** | V283-4 commit `0dd6f1a` (+8 tests) | code + test | G5 |
| **E5b** | V282-5 critic C2 finding | analysis | G5 |
| **E8** | recovery state machine (V247-x) | code | G8 |
| **E9** | V264-1 battery preflight L0 | code | G9 |

### GSN 노드 카운트 (요약)

| 노드 종류 | 개수 |
|---|---|
| **Goal** (G1 top + G2-G9 sub) | **9** |
| **Strategy** (S1) | **1** |
| **Context / Assumption / Justification** | **3** (C1, A1, J1) |
| **Evidence** (E2a, E2b, E4, E5a, E5b, E8, E9 + 4 overall) | **11** |
| **Open Claim** (OC1-OC8) | **8** |
| 전체 | **32** |

---

## 4. Open Claims — Mitigation 미완 목록

다음 cycle (V287-5+) 에서 처리해야 할 미완 안전 주장 (claims that are still open).

| Open Claim | Goal | 의도 | 차단 사유 | 권고 cycle |
|---|---|---|---|---|
| **OC1** | G2 | IntentDispatcher 본체 e-stop chain 완성 | V282-5 critic 의 C1 본체 fix 누락 | V287-5 (실 fix) |
| **OC2** | G3 | writeJointPosition joint limit clamp | 신규 작업, V288 권고 | V288 |
| **OC3** | G4 | 200ms threshold + ZMP gate + freeze | V283-2 부분 적용, V287-2 의존 | V287-5+ |
| **OC4** | G5 | WalkCycleEngine bus.setPosition → store API 교체 | V282-5 critic 의 C2 본체 fix 누락 | V287-5 (실 fix) |
| **OC5** | G6 | disconnect → dxlPower(false) 강제 | 자동 safe state 부재 | V288 |
| **OC6** | G7 | scene preview = sim only assertion | 신규 작업 | V288 |
| **OC7** | G8 | reconnect lock + queue flush 명시 | 부분 mitigation 만 존재 | V288 |
| **OC8** | G9 | low battery preflight L1 (block) | V264-1 L0 만 적용 | V287-5 |

### 우선순위 분류

- **Critical Path** (V282-5 critic 직접 매핑): OC1, OC4 → V287-5 cycle 에서 즉시 실 fix
- **High Risk** (L1 loss 직결): OC3, OC8 → V287-5 에서 정책 적용
- **Medium Risk** (defense in depth): OC2, OC5, OC6, OC7 → V288 cycle

---

## 5. Confidence Statement

본 safety case 의 신뢰도는 **moderate** 으로 평가:

- **High confidence (3건)**: G2/G5/G9 — evidence (commit + test) 존재.
- **Moderate confidence (1건)**: G4/G8 — partial evidence.
- **Low confidence (4건)**: G3/G6/G7/G8 — open claim only, mitigation 미적용.

> ISO 13482 self-assessment 5/10 + NPR 7150.2D 60% 와 일치 — 안전 case 가 50% 수준에서 시작.
> V287-5 + V288 cycle 에서 OC1-OC8 처리 후 재평가 권고.

---

## 6. 참조

- GSN Community Standard v3 (2021). https://scsc.uk/gsn
- Kelly, T., Weaver, R. "The Goal Structuring Notation — A Safety Argument Notation." DSN 2004.
- Leveson, N. G. *Engineering a Safer World*. MIT Press, 2012.
- ISO 13482:2014 — *Robots and robotic devices — Safety requirements for personal care robots*.
- NPR 7150.2D — *NASA Software Engineering Requirements*.
- `stpa-analysis-2026-05-24.md` (사이클 V287-4 자매 문서).
- V286-1 STPA hazard 8건 식별 보고.
- V282-5 critic 보고: CRITICAL C1, C2.
- V277-A, V281-5 사이클 평가.

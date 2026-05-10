# Dynamixel Wizard 2.0 — 모터 진단 / EEPROM 편집

## 한 줄 소개

ROBOTIS의 모터 단위 진단·설정 GUI. **macOS 지원**(★ 다른 RoboPlus 도구
중 거의 유일). DarwinForge의 `JointControlView`가 가장 직접적으로 비교될
도구.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 플랫폼 | Windows / **macOS** ★ / Linux |
| 라이선스 | 독점 (무료) |
| 통신 | U2D2, USB2Dynamixel, OpenCR 등 |
| 지원 모터 | DYNAMIXEL 전 세대 (AX, MX, X, P, PRO 등) |

## UI / UX 분석

### 메인 창 레이아웃

```
┌─────────────────────────────────────────────────────────┐
│  Toolbar (Connect / Scan / Firmware / About)            │
├──────────┬──────────────────────────────────────────────┤
│ Bus Tree │  Control Table (선택된 모터)                  │
│ ── Bus 1 │   Address │ Description    │ Value           │
│   ├ ID 1 │     0..1  │ Model Number   │ 29              │
│   ├ ID 2 │     3     │ ID             │ 1               │
│   …      │     4     │ Baud Rate      │ 1 (1 Mbps)      │
│          │     6..7  │ CW Angle Limit │ 0               │
│          │     ...                                      │
├──────────┼──────────────────────────────────────────────┤
│          │  Real-time scope (Position / Speed / Load)    │
│          │   ▁▂▃▄▅▆▇█▇▆▅▄▃▂▁                          │
└──────────┴──────────────────────────────────────────────┘
```

### 핵심 기능

1. **Bus Scan** — 1..253 ID 스캔 (우리 `forge scan` 동일).
2. **Control Table 직접 편집** — EEPROM/RAM 모든 레지스터를 표 형태로 편집.
3. **펌웨어 업로드** — Recovery + Update.
4. **실시간 그래프** — Position/Speed/Load 1Hz~50Hz 폴링.
5. **모터 ID 변경** — 공장 출고 ID 1 → 새 ID로 (DARwIn-OP 부품 교체 시 필수).
6. **모터 baud 변경**.

### macOS UI 특이사항

- Qt 기반 (Wizard 1.0은 Win-only Delphi였으나 2.0에서 Qt로 재작성).
- macOS에서 동작하나 macOS 네이티브 룩은 X (Windows 스타일).
- → DarwinForge는 같은 기능을 **네이티브 SwiftUI**로 더 매끄럽게 제공할 기회.

## DarwinForge 적용 — 적용된 부분

✅ **Bus 스캔** — `forge scan` + `JointControlView`의 16관절 사이드바
✅ **Position / Voltage / Temperature 표시** — `JointDetailView`의 stateGrid

## DarwinForge 적용 — 미적용 (★ 차용 후보)

### ★ 1순위 — Control Table 편집기 (고급 모드)

```swift
struct ControlTableView: View {
    let joint: JointID
    @State private var rows: [RegisterRow] = []

    var body: some View {
        Table(rows) {
            TableColumn("Addr") { Text("\($0.address)") }
            TableColumn("Name") { Text($0.name) }
            TableColumn("Value") { row in
                TextField("", value: $row.value, format: .number)
                    .onSubmit { commit(row) }
            }
            TableColumn("Type") { Text($0.type) }
        }
    }
}
```

forge-ffi에 `fc_joint_read_table(id) → JSON`, `fc_joint_write_register(id, addr, value)` 추가.

### ★ 2순위 — 실시간 그래프 (Swift Charts)

```swift
import Charts

struct JointScopeView: View {
    let joint: JointID
    @State private var samples: [JointSample] = []  // 1초 = 50 샘플

    var body: some View {
        Chart(samples) {
            LineMark(x: .value("t", $0.t), y: .value("pos", $0.position))
            LineMark(x: .value("t", $0.t), y: .value("load", $0.load))
                .foregroundStyle(.orange)
        }
        .chartYScale(domain: 0...4095)
        .frame(height: 150)
    }
}
```

50 Hz BULK_READ로 16관절 모두 동시 폴링하면 약 320 샘플/초 처리 — Mac 무리 없음.

### ★ 3순위 — ID 변경 워크플로우

부품 교체 시 시나리오:

1. 새 모터 (factory ID = 1) 단독 연결
2. DarwinForge "ID 변경 마법사" 실행
3. 입력: 새 ID (예: 17 = R_KNEE)
4. EEPROM ID 레지스터 write + 검증
5. 재부팅 후 ping 확인

각 단계 사이 HITL 승인. 잘못 하면 daisy chain 충돌.

## 출처

- ROBOTIS Wizard 2.0 매뉴얼: https://emanual.robotis.com/docs/en/software/dynamixel/dynamixel_wizard2/
- 다운로드: https://emanual.robotis.com/docs/en/software/dynamixel/dynamixel_wizard2/#installation

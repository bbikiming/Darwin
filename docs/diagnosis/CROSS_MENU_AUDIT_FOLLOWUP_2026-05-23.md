# Cross-Menu Integration Audit Follow-Up
## Cycle 192+ Deep Dive (May 23, 2026)

**Scope**: 8 top-level menus (Studio, Teach, Motion, Walk, Conversation, Pilot, Remote, Expert) — NEW gaps NOT covered by cycle 177 audit.

---

## Findings Summary

**6 new integration gaps identified**. All pose tangible user impact:
1. **P0 (Critical)**: Silent telemetry blindspots in 3 menus → analytics gap
2. **P0 (Critical)**: Missing state refresh on cross-menu navigation → stale data display
3. **P1 (High)**: Joint action buttons lack error feedback → user confusion
4. **P1 (High)**: Remote menu commands never recorded → compliance/audit gap
5. **P2 (Medium)**: Conversation clear action not wired to Harness → analytics incomplete
6. **P2 (Medium)**: Teach mode actions missing contextual labels → data loss risk

---

## Detailed Gaps

### Gap #1: Remote Menu — Zero Telemetry on User Actions [P0 CRITICAL]

**Location**: `/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift` (lines 145–200)  
**Symptom**: User clicks "Send Command", "Probe Channel", "Copy Setup", etc. → NO `Harness.shared.record(...)` fired.

```swift
// RemoteShellView line 145
Button {
    if action.requiresConfirm {
        confirmAction = action
    } else {
        Task { await shell.send(action.command) }  // ← NO telemetry
    }
}
```

**Expected behavior**: Every command execution should record:
- Command type (e.g., `demoPatchedStatus`, `remoteShellSetup`)
- Success/failure status
- Execution timestamp

**Impact**:
- Zero visibility into Remote menu usage → impossible to audit SSH/SMB command activity
- No feedback on why remote commands fail silently (network? auth?)
- Missing data for compliance/security audits

**Recommended fix**:
```swift
Task {
    let start = Date()
    do {
        await shell.send(action.command)
        Harness.shared.record(
            .remoteCommandExecuted, level: .info, actor: .user,
            data: [
                "command_type": AnyCodable(action.label),
                "duration_ms": AnyCodable(Int(Date().timeIntervalSince(start) * 1000))
            ]
        )
    } catch {
        Harness.shared.record(
            .remoteCommandFailed, level: .error, actor: .system,
            data: ["command_type": AnyCodable(action.label)]
        )
    }
}
```

---

### Gap #2: InitialSetupWizard — User Onboarding Actions Untracked [P0 CRITICAL]

**Location**: `/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/InitialSetupWizard.swift` (lines 270–430)  
**Symptom**: User completes setup steps (VNC open, SSH key setup, Master Setup, Robot Connect) → NO telemetry recorded.

```swift
// Line 276
Button {
    if let u = URL(string: "vnc://\(state.host):5900") {
        NSWorkspace.shared.open(u)
    }
    state.mark(.vnc, .completed)  // ← Visual state updated, but NO telemetry
}

// Line 420
Button {
    store.connect(endpoint: .network(host: state.host, port: 5530))  // ← No record of init flow step
}
```

**Expected behavior**: Each wizard milestone should log:
- Which step (VNC, SSH, Master Setup, etc.)
- Completion status
- Total flow duration

**Impact**:
- Can't analyze which onboarding steps users skip/fail
- No data on first-use experience → design decisions blind
- Missing funnel metrics for setup success rate

**Recommended fix**: Add step completion hooks:
```swift
.onChange(of: state.completedSteps) { _, new in
    if new.contains(.vnc) && !prev.contains(.vnc) {
        Harness.shared.record(.setupStepCompleted, level: .info, actor: .user,
                              data: ["step": AnyCodable("vnc")])
    }
}
```

---

### Gap #3: JointControlView — Action Button Failures Silent [P1 HIGH]

**Location**: `/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/JointControlView.swift` (lines 83–99)  
**Symptom**: User clicks "Torque ON", "Torque OFF", "Refresh", "E-Stop" → errors shown only as `lastError` text, NO event logging.

```swift
// Line 83–87
Button("Torque ON") {
    runJointAction { try store.bus?.setTorque(joint, enable: true) }  // ← Fails silently
}
Button("Torque OFF") {
    runJointAction { try store.bus?.setTorque(joint, enable: false) }
}
```

**Expected behavior**: Each action should record success/failure:
- Joint ID
- Action type (torque on/off, refresh, position change)
- Result (success, network error, invalid range, etc.)

**Impact**:
- No audit trail of who changed which joint state
- Can't diagnose why safety operations failed
- Hidden friction in expert diagnostic workflow

**Recommended fix**:
```swift
private func runJointAction(_ action: () throws -> Void) {
    guard store.bus != nil else {
        lastError = "Not connected"
        Harness.shared.record(.jointActionFailed, level: .warn, actor: .system,
                              data: ["reason": AnyCodable("no_bus")])
        return
    }
    do {
        try action()
        Harness.shared.record(.jointActionExecuted, level: .info, actor: .user,
                              data: ["joint": AnyCodable(joint.rawValue)])
    } catch {
        Harness.shared.record(.jointActionFailed, level: .error, actor: .system,
                              data: ["error": AnyCodable(error.localizedDescription)])
    }
}
```

---

### Gap #4: TeachModeView — Torque Toggle Actions Unlogged [P1 HIGH]

**Location**: `/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/Teach/TeachModeView.swift` (lines 148–173)  
**Symptom**: User clicks "토크 해제" (disable torque), "토크 고정" (enable torque), "캡처 시작" → only snapshot saves are logged (line 291), not torque changes or capture state transitions.

```swift
// Line 148
DFButton(.danger, size: .medium,
         action: { Task { await capture.disableAllTorque(store: store) } }) {
    Label("토크 해제", systemImage: "lock.open.fill")  // ← NO telemetry
}
```

**Expected behavior**: Log torque state changes and capture lifecycle:
```swift
.record(.teachTorqueToggled, data: ["action": "disable_all"])
.record(.teachCaptureStarted)
.record(.teachCaptureStopped)
```

**Impact**:
- Teaching session analytics incomplete
- Can't correlate capture quality with torque state
- Audit trail broken for robot safety-critical operations

**Recommended fix**: Add telemetry at `TeachCapture` level (model) or view level.

---

### Gap #5: ConversationView Clear Action — Incomplete Telemetry [P2 MEDIUM]

**Location**: `/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/Conversation/ConversationView.swift` (line 36–45)  
**Current**: ConversationViewModel.clear() logs only message count (line 103). But the VIEW button that triggers it ALSO has an optional `.keyboardShortcut("n", modifiers: [.command, .shift])` that bypasses the clear() method if bound to a different handler.

```swift
// ConversationView line 36
Button {
    vm.clear()  // ← Calls vm.clear() which logs
} label: { ... }
.keyboardShortcut("n", modifiers: [.command, .shift])  // ← Ambiguous: view or model?
```

**Expected behavior**: Confirm keyboard shortcut and button both route through same telemetry point.

**Impact**: Minor — analytics shows incomplete picture if shortcut is triggered (hard to verify without runtime trace).

**Recommended fix**: Add explicit shortcut logging:
```swift
.keyboardShortcut("n", modifiers: [.command, .shift])
.onChange(of: /* keyboard trigger */) {
    Harness.shared.record(.conversationClearedViaShortcut, ...)
    vm.clear()
}
```

---

### Gap #6: Cross-Menu State Refresh — Stale Display on Navigation [P2 MEDIUM]

**Location**: Multiple menus (Studio, Motion, JointControl, Walk) — NO `.onAppear` refresh when returning to menu after tab switch.

**Symptom**:
1. User in **Walk** menu → telemetry flowing
2. Switch to **Conversation** → RootView `section` changes
3. Switch back to **Walk** → walk data frozen at last update (may be 30+ seconds old)
4. User sees stale balance/stability values → confusion

**Example**: `/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/Studio/StudioView.swift` — no `.onAppear` to re-sync pose from latest telemetry.

**Expected behavior**: Each menu should call a "refresh from latest telemetry" on return:
```swift
.onAppear {
    store.refreshLastTelemetry()  // Fetch board state, joints, IMU, etc.
}
```

**Impact**:
- User makes decisions on stale data → wrong tuning/diagnosis
- Especially critical for Walk Lab (balance parameters) and Studio (pose inspection)
- Compliance issue: audit trail shows stale timestamps

**Recommended fix**: Add explicit refresh in each menu's `.onAppear`:
```swift
struct StudioView: View {
    .onAppear {
        // Refresh 3D pose and telemetry from live board state
        if let bus = store.bus {
            Task {
                for j in JointID.allCases {
                    if let s = try? bus.readState(j) {
                        store.jointStates[j] = s
                    }
                }
            }
        }
    }
}
```

---

## Priority Roadmap (Cycle 192+)

| Gap | Priority | Complexity | Effort | CI Impact |
|-----|----------|-----------|--------|-----------|
| #1 Remote telemetry | **P0** | Low | 30min | medium (new events) |
| #2 Setup wizard telemetry | **P0** | Medium | 1hr | high (onboarding flow) |
| #3 Joint actions logging | **P1** | Low | 20min | low (internal) |
| #4 Teach torque logging | **P1** | Low | 25min | low (internal) |
| #5 Conversation shortcut | **P2** | Trivial | 10min | none |
| #6 State refresh on nav | **P2** | Medium | 1.5hr | high (multi-menu) |

**Total effort**: ~4 hours spread across 2–3 cycles.  
**Testing**: Each gap has clear "before/after" telemetry signatures — test by watching Harness output during user actions.

---

## Notes

- **No code is broken** — all menus render and respond. Gaps are purely observability.
- **Cycle 177 audit** correctly fixed data-flow wires (Synth→Motion, Pilot↔Trial). These gaps are **missing signals** on user interactions.
- **Cascading analytics**: P0 gaps (Remote, Setup) are compliance-level; P1/P2 are UX/quality-of-life improvements.
- **Naming**: All Harness events should follow convention `.recordName` (e.g., `.remoteCommandExecuted`, `.setupStepCompleted`).


# Teach Mode Audit Report (2026-05-23)

**Scope**: Telemetry integration, cross-menu notifications, data persistence, and Motion export pathway.

**Period**: v1.12.0+ (telemetry harness adoption)

---

## Section 1: Telemetry Coverage Map

**7 TelemetryKind defined** (lines 109–115 of TelemetryEvent.swift):

| Kind | Defined | Firing Site | Payload | PII Risk |
|------|---------|------------|---------|----------|
| `teachCaptureStart` | ✅ | TeachCapture.startCapture() L94 | `connected: bool` | ❌ None |
| `teachCaptureStop` | ✅ | TeachCapture.stopCapture() L110 | `snapshot_count, consec_failures` | ❌ None |
| `teachSnapshotCaptured` | ✅ | TeachCapture.snapshot() L166 | `name_len, name_hash, name_was_default, joint_count, total_snapshots, snapshot_id` | ✅ **Redacted** (length + hash, not name) |
| `teachSnapshotApplied` | ✅ | TeachCapture.applySnapshot() L203 | `name_hash, snapshot_id, joint_count, bus_connected` | ✅ **Redacted** |
| `teachSnapshotDeleted` | ✅ | TeachCapture.deleteSnapshot() L180 | `name_hash, snapshot_id, remaining` | ✅ **Redacted** |
| `teachSnapshotsCleared` | ✅ | TeachCapture.clearSnapshots() L193 | `count_before` | ❌ None |
| `teachTorqueChanged` | ✅ **DEFINED** | ❌ **NEVER FIRED** | — | — |

**Finding**: `teachTorqueChanged` is defined in TelemetryEvent.swift (line 115) but **has zero firing sites**. Torque state is updated in three locations (TeachCapture.swift lines 53, 66, 79, 131) but no telemetry recorded.

---

## Section 2: Cross-Menu Integration Graph

### Notification Flows (Defined)

**File**: RootView.swift (lines 1191–1195)

```swift
public static let dfSwitchSection = Notification.Name("DarwinForge.SwitchSection")
public static let dfTransferPoseToStudio = Notification.Name("DarwinForge.TransferPoseToStudio")
public static let dfTransferPoseToMotion = Notification.Name("DarwinForge.TransferPoseToMotion")
```

### Teach → Studio

**Poster**: TeachModeView.swift (lines 308–313)
```swift
NotificationCenter.default.post(
    name: .dfTransferPoseToStudio, object: s.pose
)
NotificationCenter.default.post(
    name: .dfSwitchSection, object: "studio"
)
```

**Receiver**: StudioView.swift (onReceive, lines ~340)
```swift
.onReceive(NotificationCenter.default.publisher(for: .dfTransferPoseToStudio)) { note in
    if let p = note.object as? RobotPose {
        pose = p
        lastAppliedPose = p
    }
}
```

**Status**: ✅ **Working** — Studio receives pose, updates UI.

### Teach → Motion

**Poster**: ❌ **NOT FOUND**

**Receiver**: ✅ **Defined** but orphan
- dfTransferPoseToMotion notification defined (RootView.swift line 1192)
- MotionStudioView has receiver for `dfImportSynthPagesToMotionStudio` (not dfTransferPoseToMotion)
- **No code posts dfTransferPoseToMotion** anywhere

**Status**: ✅ **Infrastructure exists** | ❌ **Feature not implemented**

### Section Navigation

**Poster**: DarwinForgeApp.swift, SynthInspectorPanel.swift, Teach/TeachModeView.swift, Pilot/PilotCameraView.swift
**Receiver**: RootView.swift (line 164)
```swift
.onReceive(NotificationCenter.default.publisher(for: .dfSwitchSection)) { note in
    if let sec = note.object as? String {
        // Switch section based on sec value
    }
}
```

**Status**: ✅ **Working** — Teach posts `.dfSwitchSection("studio")` after pose transfer.

---

## Section 3: Data Persistence & Scope

### Snapshot Lifecycle

| Aspect | Implementation | Status |
|--------|---|---|
| **In-memory storage** | `@Published var snapshots: [PoseSnapshot] = []` (TeachCapture.swift L24) | ✅ Session-scoped |
| **Disk persistence** | None — reset on app restart | ❌ **Lost after quit** |
| **Export to Motion** | No direct export method | ❌ **Missing** |
| **Export to UserPoseLibrary** | TeachModeView.swift L289 `UserPoseLibrary.shared.save()` | ✅ Available |
| **Trial Library link** | No integration visible | ❌ **Not found** |
| **WalkLabSession link** | No integration visible | ❌ **Not found** |

**Finding**: Snapshots are session-ephemeral. Users must save to UserPoseLibrary or transfer to Studio/Motion within same session.

---

## Section 4: Torque Event Gap (P0 Priority)

### Current State

**Three torque mutation points** (TeachCapture.swift):
- Line 53: `disableAllTorque()` — `torqueState[j] = false`
- Line 66: `enableAllTorque()` — `torqueState[j] = true`
- Line 79: `toggleTorque()` — `torqueState[j] = nextState`
- Line 131: `captureLoop()` — `torqueState[j] = s.torqueEnabled` (read from robot)

**Zero telemetry records** for any of these.

### Recommended Fix (Cycle 193)

In TeachCapture.swift, wrap each torque mutation:

```swift
// disableAllTorque
Harness.shared.record(
    .teachTorqueChanged, level: .notice, actor: .user,
    data: ["joint": AnyCodable(j.koreanLabel),
           "new_state": AnyCodable(false),
           "scope": AnyCodable("all")]
)

// enableAllTorque — same pattern

// toggleTorque
Harness.shared.record(
    .teachTorqueChanged, level: .notice, actor: .user,
    data: ["joint": AnyCodable(j.koreanLabel),
           "new_state": AnyCodable(nextState),
           "scope": AnyCodable("single")]
)

// captureLoop — OPTIONAL (high frequency, consider sampling or aggregation)
```

---

## Section 5: Motion Export Pathway (P1 Priority)

### What Exists (Synth → Motion, Cycle 180)

**Notification**: `dfImportSynthPagesToMotionStudio` (RootView L1196)
**Poster**: SynthInspectorPanel (cycles 180, 187)
**Receiver**: MotionStudioView

### What's Missing (Teach → Motion, Cycle 192+)

Teach mode can post snapshots to Studio but **not directly to Motion**. Workaround:
1. Teach → snapshot → transfer to Studio
2. Studio → create motion page manually
3. No single-click Teach → Motion flow

**Recommended**: Implement `dfTransferSnapshotsToMotion` workflow:
- Post notification in TeachModeView with `[PoseSnapshot]` array
- MotionStudioView receives and imports as keyframes
- Auto-switch to Motion section

---

## Section 6: Summary Tallying (SessionAnalysis.swift)

**Metrics tracked**:
- `teachSnapshots` — count of `.teachSnapshotCaptured` (line 169)
- `poseLibrarySaves` — count of `.poseLibrarySaved` (line 178)

**Exposed in**:
- SessionSummaryView.swift (Harness replay UI)
- SessionMarkdownReport.swift (exported markdown)
- SessionJSONReport.swift (JSON export)

**Status**: ✅ **Functional** for captured snapshots. ❌ **No torque event metrics** (since none fire).

---

## Section 7: Gap Summary

### P0 (Critical — Specification Mismatch)

| Gap | Impact | Cycle | Effort |
|-----|--------|-------|--------|
| `teachTorqueChanged` never fires | Telemetry schema unfulfilled; zero visibility into joint-level torque changes | 193 | M (4h) |
| Orphan `dfTransferPoseToMotion` | Defined but unused; confusing API surface | 192 | S (1h cleanup) |

### P1 (Important — UX Enhancement)

| Gap | Impact | Cycle | Effort |
|-----|--------|-------|--------|
| No Teach → Motion direct export | Users must manually recreate snapshots in Motion; friction in workflow | 192 | M–L (8–12h) |
| Snapshots not persisted | Session quit loses all captures; no recovery | 193 | L (12h, requires disk schema) |
| No Trial Library link | Cannot compare Teach poses with WalkLab presets | 194 | M (6h) |

### P2 (Nice-to-have)

| Gap | Impact |
|-----|--------|
| No batch snapshot export to CSV | Data pipeline integration minimal |
| Torque frequency telemetry optional | High-frequency events may have perf cost |

---

## Section 8: Recommended Cycles 192–194

### Cycle 192: Teach → Motion Export + Cleanup
- **Task 1**: Implement `dfTransferSnapshotsToMotion(poses: [RobotPose])` notification
- **Task 2**: Add receiver in MotionStudioView to import poses as keyframes
- **Task 3**: Add UI button "Export to Motion" in TeachModeView (similar to Studio button)
- **Task 4**: Remove orphaned `dfTransferPoseToMotion` from RootView (or implement properly)
- **Telemetry**: Record `motionPageCreated` when import completes

### Cycle 193: Torque Event Coverage + Persistence
- **Task 1**: Fire `teachTorqueChanged` events in all three torque mutation points
- **Task 2**: Implement UserDefaults persistence for snapshots (snapshot list only, not poses)
- **Task 3**: Add "Restore recent snapshots" on app relaunch (optional)
- **Task 4**: Add telemetry for persistence round-trip (save/load events)
- **Test**: Verify torque events in HarnessAnalysisTests

### Cycle 194: WalkLabSession Integration
- **Task 1**: Link TeachCapture snapshots with WalkLabSession for cycle comparison
- **Task 2**: Add "Compare with preset" feature (side-by-side 3D pose viewer)
- **Task 3**: Add telemetry: `teachPresetComparison` (snapshot_id, preset_id, delta_rms)

---

## Files Modified (Summary)

| File | Changes |
|------|---------|
| TeachCapture.swift | +5 telemetry record() calls (torque events) + persistence init |
| TeachModeView.swift | +1 "Export to Motion" button + notification post |
| MotionStudioView.swift | +onReceive for dfTransferSnapshotsToMotion |
| RootView.swift | ±1 notification definition (cleanup or rename dfTransferPoseToMotion) |
| SessionAnalysis.swift | +torque event tallying (optional) |

---

## Checklist for Cycle 192 PR

- [ ] `teachTorqueChanged` fires in disableAllTorque, enableAllTorque, toggleTorque, captureLoop (sample or full)
- [ ] Teach "Export to Motion" button visible & functional
- [ ] MotionStudioView imports snapshots as keyframes without error
- [ ] Auto-switch to Motion section on export
- [ ] HarnessAnalysisTests verify torque event count
- [ ] No PII in torque payload (joint ID only, redact name)
- [ ] Orphan notification cleaned up or implemented
- [ ] No console warnings from orphan receivers

---

**Audit Date**: 2026-05-23  
**Auditor**: Explorer Agent  
**Status**: Ready for cycle planning

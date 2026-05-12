# DarwinForge V2 — 업그레이드 계획 (Production-Ready)

> 본 문서는 [`AUDIT_DARWIN_V2.md`](AUDIT_DARWIN_V2.md)의 점검을 행동 항목으로 환원한다.
> 각 항목은 **(왜 필요한가, 출처, 어떻게 측정할까, 어떻게 구현할까)**를 갖춘다.

---

## 0. 결론 먼저

**4주 안에 다음을 한다**:

- **Week 1 (P0 — 출시 차단 해소)**: 슬라이더 버스 플러드 / Live Apply race / USB drop / 카메라 / STL banner / 메뉴 명령. 본 PR.
- **Week 2 (P1 — 핵심 가치 증명)**: Sync_Write FFI 노출, walking IK 실 모터 발행 (조건부), motion library preload, Help center.
- **Week 3 (P2 — 차별화)**: 카메라 비전 라이브, Strategy 자동, SQLite persistence, undo/redo.
- **Week 4 (P3 — 장기 자산)**: 거대 파일 분리, UI snapshot 픽셀 회귀, ROS2 bridge.

---

## 1. 우선순위 정의

| 등급 | 의미 | 차단 영향 |
|---|---|---|
| **P0** | 실 로봇 안전·신뢰 차단 | 본 PR (즉시) |
| **P1** | 핵심 가치 명세 미충족 | 1주 |
| **P2** | 사용성·차별화 | 2주 |
| **P3** | 장기 자산·확장성 | 4주 |

---

## 2. P0 — 실 로봇 안전·신뢰

### P0-A. 슬라이더 edit-end gating

**왜**: 슬라이더 매 프레임 setPosition 16개 = 800ms 버스 플러드 ([AUDIT §1.1](AUDIT_DARWIN_V2.md#11)).

**근거**:
- ROBOTIS-Framework `robotis_controller.cpp` — Sync_Write 8ms 루프
- macOS HIG "Sliders" — *commit on release* 패턴 (NSSlider isContinuous=false)
- ROS rqt_joint_trajectory_controller — release-to-publish

**구현**:
1. `PoseInspector` Slider에 `onEditingChanged: { editing in pose-on-edit-end }` 추가
2. drag 중에는 `pose` 상태만 업데이트, hardware 호출 X
3. drag end 시 1번만 `onApplyToHardware(pose)` 호출

**측정**:
- Slider 한 번 드래그 (시작→끝) 동안 setPosition 호출 회수 == 1
- 드래그 중 화면은 60fps, 드래그 끝 후 200ms 안에 모터 반영

### P0-B. 변경된 관절만 발행 (diff apply)

**왜**: liveApply 한 슬라이더만 움직였는데도 16개 모두 setPosition — 패킷 15개 낭비.

**근거**:
- DynamixelSDK `groupBulkWrite` — 변경된 ID만 build
- ROS dynamixel_workbench — pre-existing position과 비교 후 발행

**구현**:
1. `StudioView`에 `lastAppliedPose: RobotPose?` 캐시
2. `applyToHardware(_ pose:)`에서 `joints.filter { lastAppliedPose?.raw($0) != pose.raw($0) }` 만 발행
3. 성공 시 `lastAppliedPose = pose`

**측정**:
- 1관절만 변경 후 apply → setPosition 호출 1회

### P0-C. Live Apply confirm race 수정

**왜**: confirm alert 미해결 상태에서 슬라이더 동작 가능.

**구현**:
1. Toggle set에서 `liveApply = true`를 alert 결과 후로 미룸
2. alert "켤게요"에서만 `liveApply = true` + `hasAcceptedLiveApply = true`
3. alert 취소 → toggle false 유지

**측정**:
- toggle on → alert 표시 → 슬라이더 변경 → setPosition 호출 0 (사용자 동의 전)
- "켤게요" 누른 후 → 슬라이더 변경 → setPosition 호출 1

### P0-D. USB drop watchdog

**왜**: USB 빠지면 status가 .connected에 머무름 → 사용자 잘못된 신뢰.

**근거**:
- macOS IOKit `IOServiceAddMatchingNotification(kIOServiceTerminate)` — 공식 hot-plug 감지
- Apple Sample "USBPrivateDataSample" — USB 디바이스 detect 패턴

**구현 (간이판, P0)**:
1. `runTelemetryLoop`에서 `boardSnapshot()` 호출이 throw하면 내부 카운터 +1
2. 연속 3회 fail → `bus = nil`, `status = .error("로봇과의 연결이 끊겼어요. 케이블·전원을 확인해 주세요.")`
3. UI: 사용자가 "다시 연결" 버튼 누르면 자동 재연결 시도

**구현 (P1 확장)**: IOKit notification으로 즉시 감지.

**측정**:
- USB 케이블 빼기 → 3초 내 status가 .error로 전환
- 슬라이더 동작 시도 시 disabled 상태로 표시

### P0-E. Camera 정면 기본

**왜**: 사용자가 처음 봤을 때 25° 비스듬 → 인지 비용.

**근거**:
- Webots, RViz, Foxglove 모두 정면 default
- Apple HIG "First-time experience" — predictable initial state

**구현**:
- `InteractiveSceneView.orbitAzimuth = 0`, `orbitElevation = 0.10` 기본값 변경

### P0-F. STL fallback banner

**왜**: 메쉬 로드 실패해도 사용자 모름.

**구현**:
1. `MeshRig.init()`이 실패 사유 throw → `RobotScene3D.makeNSView`에서 캐치
2. `RobotScene3D`에 `@State meshFallbackActive` 노출
3. 화면 좌하단에 작은 yellow banner: "기본 모델 로드 실패 — 단순 형상으로 표시 중"

**측정**:
- Resources/Meshes/ 디렉토리 비우면 banner 표시
- 메쉬 정상 시 banner 미표시

### P0-G. macOS Menu commands

**왜**: ⌘1..5 단축키가 메뉴에 없음 → 사용자가 단축키 존재 모름.

**근거**:
- Apple HIG "Menus" — *모든 단축키는 메뉴에 노출되어야 한다*
- WWDC 2020 "Build SwiftUI views for widgets" — CommandMenu 패턴

**구현**:
1. `DarwinForgeApp.swift`에 `CommandMenu("보기")` 추가
2. 5 섹션 + e-stop 메뉴 항목
3. 각 항목에 단축키 명시

**측정**:
- 메뉴바 "보기" 클릭 → 5 섹션 노출, 단축키 표시

### P0-H. Starter motion library

**왜**: 첫 실행 시 빈 페이지 1개. 사용자가 "이걸로 뭘 하지?" 막힘.

**근거**:
- ROBOTIS RoboPlus Action: 출시 시 18 prebundled (Walking, Sit, Stand, Bow, Wave, etc.)
- Apple Logic Pro / Final Cut: 빈 프로젝트에 sample 항목

**구현**:
1. `MotionStudioView.starterDoc()`에 5 페이지 prebundle:
   - 페이지 1: "기본 자세" (idle pose 1 step)
   - 페이지 2: "T 자세" (T-pose 1 step)
   - 페이지 3: "오른손 인사" (3 step wave)
   - 페이지 4: "고개 끄덕" (2 step nod)
   - 페이지 5: "양쪽 인사" (mirror wave 4 step)
2. 모든 페이지가 `walk_ready`로 시작·종료해 안전

**측정**:
- 첫 실행 시 사이드바 5개 페이지 표시
- 각 페이지 재생 → 시각적으로 동작이 의미 있음

---

## 3. P1 — 핵심 가치 (1주 내)

### P1-A. Sync_Write FFI 노출

**왜**: 16관절 한 패킷 = 12ms (현재: 800ms). 16배 throughput.

**근거**:
- Dynamixel Protocol 1.0 SYNC_WRITE [emanual.robotis.com/docs/en/dxl/protocol1/#sync-write](https://emanual.robotis.com/docs/en/dxl/protocol1/#sync-write)
- forge-core::dynamixel::sync 모듈은 Sprint 2에서 이미 작성됨 (`PROGRESS.md`)

**구현**:
1. `forge-core/forge-ffi/src/lib.rs`에 `fc_bus_sync_write_positions(handle, ids[], goal_positions[], len)` 노출
2. cbindgen으로 헤더 갱신
3. Swift `Bus.swift`에 `setPositions(_ targets: [JointID: UInt16])` 추가
4. `BusActor.apply(pose:)`를 sync_write로 swap

### P1-B. Walking IK + 실 모터 발행

**왜**: WalkLab의 핵심 가치 부재. 발 trace만 그리고 로봇은 안 움직임.

**근거**:
- ROBOTIS-OP2 `op2_walking_module` (Apache 2.0, [research/robotis-official/ROBOTIS-OP2/op2_walking_module](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module))
- Hong et al. (2014) "DARwIn's Evolution"
- Schwarz et al. (2014) NimbRo gait controller

**구현 단계**:
1. forge-core::walk에 IK (foot pose → 6 leg joints) — Hong et al. 식 (4)~(6)
2. `WalkEngine.tick(dtMs)`이 leg targets 반환하도록
3. Swift WalkLab에 "실 로봇 적용" 토글 (default OFF, OFF 시 sim trace만)
4. 토글 ON 시 매 50ms 발행 (Sync_Write로)

**안전**:
- 토크 ON 확인 selfcheck
- Hip pitch ±10° 이상 명령 시 추가 confirm

### P1-C. Help / Cheat Sheet 모달

**왜**: 단축키, 안전 매뉴얼이 분산. 첫 사용자 막막.

**구현**:
1. ⌘? 단축키 또는 메뉴 "도움말" → modal sheet
2. 4섹션: 단축키 / 연결 절차 / 안전 / 자주 묻는 질문
3. "처음 사용 가이드" 버튼: Studio onboarding panel 다시 표시

### P1-D. Joint angle limits 정확화

**왜**: RoboPlus 기본 모션 import 시 클램프되어 변형됨.

**구현**:
- `joint-conventions.md` 재검증
- ROBOTIS official limits로 갱신
- import 시 클램프된 step에 warning badge

---

## 4. P2 — 사용성·차별화 (2주 내)

### P2-A. AVFoundation 카메라 → forge-core::vision

**왜**: Strategy의 입력이 raw 숫자. 사용자가 비전 결과를 못 봄.

**구현**:
1. AVCaptureSession (macOS 카메라 또는 외부 USB 카메라)
2. CMSampleBuffer → forge-core::vision::FrameAdapter
3. 결과 (ballPixelCount, 위치) 자동 갱신

### P2-B. SQLite Persistence

**왜**: pose / motion library / settings 재시작 시 사라짐.

**구현**:
1. GRDB.swift 추가
2. 테이블: `motion_pages`, `pose_presets`, `recent_telemetry`, `settings`
3. ConnectionStore + MotionStudioView가 자동 save/load

### P2-C. Undo / Redo

**구현**:
1. `@Environment(\.undoManager)` 패턴
2. PoseInspector 슬라이더 commit, MotionStudioView step 추가/삭제 모두 register

### P2-D. Multi-channel 시계열 plot

**왜**: 현재 sparkline 1개씩만. Foxglove 수준의 동시 비교 부재.

**구현**: Swift Charts (macOS 13+) — 16관절 라인 + 마우스오버 readout.

---

## 5. P3 — 장기 자산 (4주 내)

### P3-A. 거대 파일 분리

| 현 | 분리 후 |
|---|---|
| `RobotScene3D.swift` (936줄) | `RobotScene3D.swift` (200), `DarwinOP2Rig.swift` (450), `RobotSceneRenderer.swift` (140), `RobotSceneAxes.swift` (140) |
| `MotionStudioView.swift` (448) | View + `MotionSidebar`, `MotionTimelineSection`, `MotionInspectorColumn` |
| `StudioView.swift` (495) | View + `StudioOnboardingPanel`, `StudioBodyMapPanel`, `StudioTelemetryStrip` |
| `RootView.swift` (389) | View + `RootSidebar`, `RootShortcutCommands` |

### P3-B. UI Snapshot 회귀 (픽셀 비교)

**도구**: pointfreeco/swift-snapshot-testing.

**구현**:
1. `RobotSnapshotTests`를 image diff로 전환
2. `__Snapshots__/` 디렉토리에 기준 PNG
3. CI에서 diff > 1% 시 fail

### P3-C. ROS2 bridge

**왜**: RoboCup / 학계 사용자가 ROS2 toolchain에 통합.

**구현**:
- forge-core에 `forge-ros2-bridge` crate (rclrs 또는 zenoh-cpp)
- Topics: `/joint_states`, `/joint_commands`, `/imu/data`, `/walk_cmd_vel`
- DDS over LAN으로 Foxglove 연동

### P3-D. Webots co-sim

**왜**: 시뮬에서 자세 미리 검증.

**구현**:
- Webots `robotis-op2.proto` controller
- Forge → DDS → Webots Wb_supervisor

### P3-E. Notarization + DMG

**왜**: 외부 배포 시 Gatekeeper 차단.

**구현**:
- Apple Developer ID (개인 또는 팀)
- `xcrun notarytool` integration

---

## 6. 실행 캘린더

```
Week 1 — P0 (본 PR)
├─ Day 1: 카메라 + STL banner + 메뉴 (P0-E/F/G)
├─ Day 2: Slider edit-end + diff apply (P0-A/B)
├─ Day 3: Live Apply race + USB watchdog (P0-C/D)
├─ Day 4: Starter motion library (P0-H)
└─ Day 5: 회귀 테스트 + 빌드 검증

Week 2 — P1
├─ Day 1-2: Sync_Write FFI (P1-A)
├─ Day 3-4: Walking IK 실 모터 (P1-B)
└─ Day 5: Help modal + limits (P1-C/D)

Week 3 — P2
├─ Day 1-2: AVFoundation vision (P2-A)
├─ Day 3-4: SQLite persistence (P2-B)
└─ Day 5: Undo/redo + multi-plot (P2-C/D)

Week 4 — P3 + 출시 준비
├─ Day 1-2: 거대 파일 분리 (P3-A)
├─ Day 3: Snapshot 회귀 (P3-B)
├─ Day 4: 베타 사용자 ≥ 3명 — 평점 점검
└─ Day 5: Notarization + DMG → release v0.7
```

---

## 7. 측정 / 성공 지표

| 메트릭 | 출시 (Week 4) | 3개월 |
|---|---|---|
| Slider 1 tick → setPosition 호출 | 1 (현재 16+) | 1 |
| 16관절 일괄 적용 latency | < 30ms (현재: 800ms) | < 20ms |
| USB drop 감지 시간 | < 3초 (현재: 무한) | < 500ms (IOKit) |
| 첫 실행 시 motion library 페이지 수 | 5 (현재: 1) | 18 |
| 메뉴바 단축키 노출 비율 | 100% (현재: 0%) | 100% |
| Swift UI 단위 테스트 | 12+ (현재: 0) | 30+ |
| 비전 통합 (Strategy live) | n/a | ✅ |
| Walking 실 모터 | n/a | ✅ |
| Crash-free sessions | ≥ 99% | ≥ 99.5% |
| RoboCup 팀 채택 | n/a | ≥ 1 |

---

## 8. 본 PR (P0) 변경 요약

이번 commit에서 다음을 제공:

- [ ] `PoseInspector` slider edit-end gating
- [ ] `StudioView` diff-based hardware apply + lastAppliedPose 캐시
- [ ] `StudioView` live-apply confirm race 수정
- [ ] `ConnectionStore` USB drop watchdog (3 strikes → status .error)
- [ ] `InteractiveSceneView` 정면 기본 (azimuth=0)
- [ ] `RobotScene3D` STL fallback banner expose
- [ ] `DarwinForgeApp` macOS Menu commands (5 섹션 + e-stop + help)
- [ ] `MotionStudioView` starter motion library 5 pages
- [ ] 회귀 테스트 추가 (slider commit, diff apply, USB watchdog)
- [ ] `swift build` + `swift test` green

→ 진행 상황은 [`PROGRESS.md`](../../PROGRESS.md) Sprint 8 기록.

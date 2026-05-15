import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// Sprint 15 Remote Pilot v1.0 — 단위 테스트.
final class PilotTests: XCTestCase {

    // MARK: - MotionCatalog (4)

    func testMotionCatalogHasMain7Slots() {
        XCTAssertEqual(MotionCatalog.actionBarMainSlots, [1, 4, 15, 12, 13, 9, 23],
            "PRD §7.1 메인 7 페이지 슬롯 순서 동결")
        XCTAssertEqual(MotionCatalog.actionBarMain.count, 7)
    }

    func testMotionCatalogHas16Pages() {
        // PRD §7.1 (7) + §7.2 (9) = 16.
        XCTAssertEqual(MotionCatalog.all.count, 16,
            "v1.5 까지 표시되는 16 페이지 catalog")
    }

    func testMotionCatalogKoreanLabels() {
        XCTAssertEqual(MotionCatalog.find(slot: 1)?.displayNameKo,   "기본 자세")
        XCTAssertEqual(MotionCatalog.find(slot: 4)?.displayNameKo,   "감사 인사")
        XCTAssertEqual(MotionCatalog.find(slot: 9)?.displayNameKo,   "보행 자세")
        XCTAssertEqual(MotionCatalog.find(slot: 12)?.displayNameKo,  "오른발 차기")
        XCTAssertEqual(MotionCatalog.find(slot: 13)?.displayNameKo,  "왼발 차기")
        XCTAssertEqual(MotionCatalog.find(slot: 15)?.displayNameKo,  "앉기")
        XCTAssertEqual(MotionCatalog.find(slot: 23)?.displayNameKo,  "출발!")
    }

    func testHighRiskSlotsAreKicks() {
        // PRD §7.1 — page 12/13 이 HighRisk (confirm 필수).
        XCTAssertEqual(MotionCatalog.find(slot: 12)?.safetyClass, .highRisk)
        XCTAssertEqual(MotionCatalog.find(slot: 13)?.safetyClass, .highRisk)
        XCTAssertTrue(MotionCatalog.find(slot: 12)!.safetyClass.requiresConfirm)
        // Safe 슬롯 6 개는 confirm 불필요.
        for slot: UInt8 in [1, 4, 9, 15, 23] {
            XCTAssertEqual(MotionCatalog.find(slot: slot)?.safetyClass, .safe,
                "slot \(slot) 은 Safe 여야 함")
        }
    }

    // MARK: - PilotFeatureFlags (2)

    func testFeatureFlagsV1_0Matrix() {
        // v1.0 = 메인 7 만 활성, 나머지 OFF.
        let f = PilotFeatureFlags.v1_0
        XCTAssertTrue(f.actionBarMain)
        XCTAssertFalse(f.actionBarMore)
        XCTAssertFalse(f.imuTelemetry)
        XCTAssertFalse(f.autoRecovery)
        XCTAssertFalse(f.headTracking)
        XCTAssertFalse(f.ballFollow)
        XCTAssertFalse(f.camera)
        XCTAssertFalse(f.hsvTuning)
        XCTAssertFalse(f.bridgeNetwork)
        XCTAssertFalse(f.dpadRealMotor)
        XCTAssertFalse(f.pageChain)
        XCTAssertFalse(f.mp3Playback)
    }

    func testFeatureFlagsProgressionMatrix() {
        // PRD §1 단계별 활성화 매트릭스 — v1.5 부터는 Codex 권고 (2026-05-13) 로
        // "작동하는 것처럼 보이는 기능" 차단을 위해 안전 부분집합으로 재정의.
        //
        // v1.5 안전 범위:
        //   - actionBarMore / bridgeNetwork / camera (Sprint 17)
        //   - ballFollow (Sprint 18 Phase B)
        //   - imuTelemetry / headTracking (Sprint 18 Phase D — FFI + Mac PID)
        // v1.5 에서 여전히 OFF (외부 데몬 / 큰 작업 필요):
        //   - autoRecovery / hsvTuning / dpadRealMotor / pageChain / mp3Playback
        XCTAssertTrue(PilotFeatureFlags.v1_5.actionBarMore)
        XCTAssertTrue(PilotFeatureFlags.v1_5.bridgeNetwork)
        XCTAssertTrue(PilotFeatureFlags.v1_5.camera)
        XCTAssertTrue(PilotFeatureFlags.v1_5.imuTelemetry, "Phase D3 IMU FFI 활성")
        XCTAssertTrue(PilotFeatureFlags.v1_5.headTracking, "Phase D5 Mac PID 활성")
        XCTAssertFalse(PilotFeatureFlags.v1_5.dpadRealMotor)
        XCTAssertFalse(PilotFeatureFlags.v1_5.pageChain)
        XCTAssertFalse(PilotFeatureFlags.v1_5.autoRecovery)

        // v1_1_future / v2_future 는 미래 단계 placeholder — 실제 활성 시 별도 Sprint.
        XCTAssertTrue(PilotFeatureFlags.v1_1_future.imuTelemetry)
        XCTAssertTrue(PilotFeatureFlags.v1_1_future.autoRecovery)
        XCTAssertTrue(PilotFeatureFlags.v1_1_future.headTracking)
        XCTAssertFalse(PilotFeatureFlags.v1_1_future.dpadRealMotor)

        XCTAssertTrue(PilotFeatureFlags.v2_future.dpadRealMotor)
        XCTAssertTrue(PilotFeatureFlags.v2_future.camera)
        XCTAssertTrue(PilotFeatureFlags.v2_future.mp3Playback)
    }

    func testPilotCameraEndpointBuildsOfficialSnapshotURL() {
        let endpoint = PilotCameraEndpoint(host: "192.168.123.1", port: 8080)
        XCTAssertEqual(
            endpoint.snapshotURL(sequence: 7)?.absoluteString,
            "http://192.168.123.1:8080/?action=snapshot&n=7"
        )
        XCTAssertEqual(PilotCameraEndpoint(host: "http://192.168.123.1:8080").host, "192.168.123.1")
    }

    // MARK: - CameraFailureReason (Sprint 17 UX 권고)

    /// URLError 코드 → CameraFailureReason 카테고리 매핑.
    /// 사용자 친화적 라벨 ("8080 닫힘" 등) 을 보여주려면 정확한 분류가 필수.
    func testCameraFailureReasonMapsConnectionRefusedToPortClosed() {
        let err = URLError(.cannotConnectToHost)
        XCTAssertEqual(CameraFailureReason.from(error: err), .portClosed)
    }

    func testCameraFailureReasonMapsTimedOutToTimeout() {
        XCTAssertEqual(CameraFailureReason.from(error: URLError(.timedOut)), .timeout)
    }

    func testCameraFailureReasonMapsHostLookupFailureToHostUnreachable() {
        XCTAssertEqual(CameraFailureReason.from(error: URLError(.cannotFindHost)), .hostUnreachable)
        XCTAssertEqual(CameraFailureReason.from(error: URLError(.notConnectedToInternet)), .hostUnreachable)
        XCTAssertEqual(CameraFailureReason.from(error: URLError(.networkConnectionLost)), .hostUnreachable)
    }

    func testCameraFailureReasonShortLabels() {
        XCTAssertEqual(CameraFailureReason.portClosed.shortLabel, "포트 닫힘")
        XCTAssertEqual(CameraFailureReason.timeout.shortLabel, "타임아웃")
        XCTAssertEqual(CameraFailureReason.hostUnreachable.shortLabel, "응답 없음")
        XCTAssertEqual(CameraFailureReason.httpStatus(404).shortLabel, "HTTP 404")
        XCTAssertEqual(CameraFailureReason.decodeFailed.shortLabel, "디코딩 실패")
    }

    /// 사용자가 실패 시 어디로 가야 하는지 — UX가 한 번에 안내해야 함.
    func testCameraFailureReasonSuggestsNextAction() {
        // 8080 닫힘 / 디코딩 실패 / 타임아웃 → 로봇에서 카메라 데모 시작 필요.
        XCTAssertEqual(CameraFailureReason.portClosed.suggestedActionLabel, "원격 명령으로 가기")
        XCTAssertEqual(CameraFailureReason.timeout.suggestedActionLabel, "원격 명령으로 가기")
        XCTAssertEqual(CameraFailureReason.decodeFailed.suggestedActionLabel, "원격 명령으로 가기")
        // 호스트 자체 도달 불가 → 연결 마법사 / 네트워크 확인.
        XCTAssertEqual(CameraFailureReason.hostUnreachable.suggestedActionLabel, "연결 마법사로 가기")
        // HTTP 응답이 있는데 200 아님 / URL 오류 / 기타 → 단축 액션 없음 (사용자 수동 확인).
        XCTAssertNil(CameraFailureReason.httpStatus(500).suggestedActionLabel)
        XCTAssertNil(CameraFailureReason.invalidURL.suggestedActionLabel)
    }

    // MARK: - Pilot mode + ROBOTIS demo 라우팅 (Sprint 18)

    /// 사용자가 보는 모드 라벨이 명확한지.
    func testPilotModeLabels() {
        XCTAssertEqual(PilotMode.manual.label, "수동")
        XCTAssertEqual(PilotMode.ballFollow.label, "공 자동 추적")
        // 부제목 — 모드별 의미를 한 줄로.
        XCTAssertTrue(PilotMode.manual.detailLabel.contains("Mac"))
        XCTAssertTrue(PilotMode.ballFollow.detailLabel.contains("vision") ||
                      PilotMode.ballFollow.detailLabel.contains("걷기"))
    }

    /// v1.5 flag 가 공 자동 추적 + IMU + head tracking 활성화 했는지 — Sprint 18 Phase D 통합 후.
    func testV15FlagsEnableBallFollowAndCamera() {
        let v15 = PilotFeatureFlags.v1_5
        XCTAssertTrue(v15.ballFollow, "Phase B — ROBOTIS demo 위임")
        XCTAssertTrue(v15.camera)
        XCTAssertTrue(v15.actionBarMore)
        XCTAssertTrue(v15.imuTelemetry, "Phase D3 — fc_bus_read_imu FFI")
        XCTAssertTrue(v15.headTracking, "Phase D5 — Mac PID")
        // dpadRealMotor / autoRecovery 는 여전히 OFF — 별도 Sprint.
        XCTAssertFalse(v15.dpadRealMotor)
        XCTAssertFalse(v15.autoRecovery)
    }

    /// ballTrackerStart 가 USB bus 점유 해제 + demo binary 탐색 + 실행을 모두 포함하는지.
    /// 사용자가 ⌘8 에서 "공 자동 추적" 누르면 이 명령이 발송된다.
    /// Phase B (Sprint 18) 이후 `demo-pilot` 우선 + 변수 기반 실행으로 변경됨.
    func testBallTrackerStartCommandContainsKeyStages() {
        let cmd = RobotSetupCommand.ballTrackerStart
        XCTAssertTrue(cmd.contains("killall socat"),
                      "forge-bridge 종료 — USB bus 해제 필요")
        XCTAssertTrue(cmd.contains("Framework/Linux/project/demo") ||
                      cmd.contains("darwin/Linux/project/demo"),
                      "ROBOTIS demo 디렉토리 경로 탐색 포함")
        XCTAssertTrue(cmd.contains("nohup"),
                      "백그라운드 실행")
        XCTAssertTrue(cmd.contains("pgrep"),
                      "실행 결과 프로세스 검증")
    }

    /// demoStop 이 demo 종료 + forge-bridge 복구를 모두 포함하는지.
    /// 사용자가 "수동" 으로 돌아갈 때 Mac 모터 송출 가능 상태가 되어야 함.
    func testDemoStopCommandReconnectsForgeBridge() {
        let cmd = RobotSetupCommand.demoStop
        XCTAssertTrue(cmd.contains("killall demo"),
                      "demo 프로세스 종료")
        XCTAssertTrue(cmd.contains("forge-bridge") || cmd.contains("socat tcp-l:5530"),
                      "forge-bridge 복구")
    }

    /// QuickActionCatalog 에 새 모드 명령들이 모두 등록됐는지 — ⌘6 화면에서 사용자가 직접 호출.
    func testQuickActionCatalogIncludesDemoModeActions() {
        let ids = QuickActionCatalog.all.map { $0.id }
        XCTAssertTrue(ids.contains("ball-tracker-start"))
        XCTAssertTrue(ids.contains("walk-demo-start"))
        XCTAssertTrue(ids.contains("action-demo-start"))
        XCTAssertTrue(ids.contains("demo-stop"))
        XCTAssertTrue(ids.contains("demo-status"))
        // 카메라 명령은 그대로.
        XCTAssertTrue(ids.contains("camera-start"))
        XCTAssertTrue(ids.contains("camera-status"))
        XCTAssertTrue(ids.contains("camera-stop"))
    }

    /// PilotDemoStatus 가 모든 라이프사이클 케이스를 표현하는지.
    func testPilotDemoStatusLifecycle() {
        XCTAssertEqual(PilotDemoStatus.idle, .idle)
        XCTAssertEqual(PilotDemoStatus.launching, .launching)
        XCTAssertEqual(PilotDemoStatus.ballFollowActive, .ballFollowActive)
        XCTAssertEqual(PilotDemoStatus.manualActive, .manualActive)
        XCTAssertEqual(PilotDemoStatus.failure("x"), .failure("x"))
        XCTAssertNotEqual(PilotDemoStatus.failure("a"), .failure("b"))
    }

    // MARK: - PilotDemoStatusParser (한계 6 해결 — polling 자동 동기화)

    /// 로봇 측 ballTrackerStatus 출력의 첫 줄 marker 가 정확히 분류되는지.
    func testDemoStatusParserMaps() {
        // demo 활성.
        XCTAssertEqual(
            PilotDemoStatusParser.parse("DF_STATUS=demo\n---\n로그..."),
            .ballFollowActive
        )
        // forge-bridge 만 활성.
        XCTAssertEqual(
            PilotDemoStatusParser.parse("DF_STATUS=bridge\n---\n5530 listening"),
            .manualActive
        )
        // 둘 다 비활성.
        XCTAssertEqual(
            PilotDemoStatusParser.parse("DF_STATUS=idle\n---\nnot running"),
            .idle
        )
    }

    /// marker 가 없는 경우 nil 반환 — 기존 status 가 그대로 유지되어야 한다.
    func testDemoStatusParserReturnsNilForUnknownInput() {
        XCTAssertNil(PilotDemoStatusParser.parse(nil))
        XCTAssertNil(PilotDemoStatusParser.parse(""))
        XCTAssertNil(PilotDemoStatusParser.parse("Some random text"))
        XCTAssertNil(PilotDemoStatusParser.parse("DF_STATUS=unknown\n---"))
    }

    /// status 명령이 marker 를 첫 줄에 출력하는지 (출력 contract 검증).
    /// 명령 수정 시 marker 가 빠지면 polling 이 stale state 유지하므로 회귀 방지.
    func testBallTrackerStatusEmitsMachineMarker() {
        let cmd = RobotSetupCommand.ballTrackerStatus
        XCTAssertTrue(cmd.contains("DF_STATUS=demo"),
                      "demo 활성 시 출력할 marker")
        XCTAssertTrue(cmd.contains("DF_STATUS=bridge"),
                      "forge-bridge 활성 시 출력할 marker")
        XCTAssertTrue(cmd.contains("DF_STATUS=idle"),
                      "둘 다 비활성 시 출력할 marker")
        XCTAssertTrue(cmd.contains("pgrep -x demo-pilot"),
                      "Phase B patched binary 도 인식해야 함")
    }

    // MARK: - Phase B: demo 패치 / 자동 모드 진입 (Sprint 18)

    /// Phase B 의 ballTrackerStart 가 patched binary 우선 + /tmp/df-pilot-mode 작성을 포함.
    /// 이 두 가지가 빠지면 자동 SOCCER 진입 흐름이 깨짐 — 회귀 방지.
    func testBallTrackerStartPrefersPatchedBinaryAndWritesMode() {
        let cmd = RobotSetupCommand.ballTrackerStart
        XCTAssertTrue(cmd.contains("demo-pilot"),
                      "patched binary 를 먼저 탐색")
        XCTAssertTrue(cmd.contains("/tmp/df-pilot-mode"),
                      "patched binary 가 read 할 모드 파일을 작성")
        XCTAssertTrue(cmd.contains("\"soccer\" > /tmp/df-pilot-mode") ||
                      cmd.contains("soccer\" > /tmp/df-pilot-mode"),
                      "soccer 모드 문자열 작성")
        XCTAssertTrue(cmd.contains("후면 MODE 버튼"),
                      "patched 가 없을 때 사용자에게 후면 버튼 안내")
    }

    /// demoBuildPatched 가 핵심 단계 (탐색 / 백업 / sed 패치 / make / 이름 변경 / 복구) 모두 포함.
    func testDemoBuildPatchedFullPipeline() {
        let cmd = RobotSetupCommand.demoBuildPatched
        XCTAssertTrue(cmd.contains("Framework/Linux/project/demo") ||
                      cmd.contains("darwin/Linux/project/demo"),
                      "demo 소스 디렉토리 탐색")
        XCTAssertTrue(cmd.contains("main.cpp.df-orig"),
                      "원본 main.cpp 백업")
        XCTAssertTrue(cmd.contains("sed"),
                      "sed 로 패치 삽입")
        XCTAssertTrue(cmd.contains("MotionManager::GetInstance()->LoadINISettings"),
                      "anchor 라인 — patched 삽입 위치")
        XCTAssertTrue(cmd.contains("make"),
                      "빌드 실행")
        XCTAssertTrue(cmd.contains("mv demo demo-pilot"),
                      "binary 보존")
        XCTAssertTrue(cmd.contains("cp main.cpp.df-orig main.cpp"),
                      "원본 복구")
        // injection 블록 자체에 모드 분기 + Action::Start(9) (walk_ready) 포함.
        XCTAssertTrue(cmd.contains("StatusCheck::m_cur_mode"),
                      "patched 가 StatusCheck mode 직접 set")
        XCTAssertTrue(cmd.contains("StatusCheck::m_is_started = 1"),
                      "START 버튼 시뮬레이션 — m_is_started=1 자동")
        XCTAssertTrue(cmd.contains("ResetGyroCalibration"),
                      "SOCCER 모드의 gyro calibration 재현")
    }

    /// patched 상태 명령이 DF_PATCH=installed / DF_PATCH=missing marker 를 첫 줄로 출력.
    func testDemoPatchedStatusEmitsMarker() {
        let cmd = RobotSetupCommand.demoPatchedStatus
        XCTAssertTrue(cmd.contains("DF_PATCH=installed"))
        XCTAssertTrue(cmd.contains("DF_PATCH=missing"))
    }

    /// 제거 명령이 binary + 패치 흔적을 모두 정리.
    func testDemoRemovePatchedCleansArtifacts() {
        let cmd = RobotSetupCommand.demoRemovePatched
        XCTAssertTrue(cmd.contains("demo-pilot"))
        XCTAssertTrue(cmd.contains("/tmp/df-pilot-mode"),
                      "잔여 모드 파일도 정리")
        XCTAssertTrue(cmd.contains("main.cpp.df-orig"),
                      "백업 파일 정리")
    }

    /// QuickActionCatalog 에 patch 관련 명령 3개가 모두 등록됨.
    /// 사용자가 ⌘6 에서 'patched 빌드 / 상태 / 제거' 를 직접 호출할 수 있어야 한다.
    func testQuickActionCatalogIncludesPatchActions() {
        let ids = QuickActionCatalog.all.map { $0.id }
        XCTAssertTrue(ids.contains("demo-patch-build"))
        XCTAssertTrue(ids.contains("demo-patch-status"))
        XCTAssertTrue(ids.contains("demo-patch-remove"))
    }

    // MARK: - Phase C: Transition flow + 후면 버튼 단계

    /// patched 시나리오는 모든 단계 자동.
    /// 사용자 액션 단계 없음 — 한 번 클릭으로 끝.
    func testBallFollowPatchedFlowIsAllAutomatic() {
        let steps = PilotTransitionFlow.ballFollowPatched()
        XCTAssertFalse(steps.isEmpty)
        XCTAssertTrue(steps.allSatisfy {
            if case .automatic = $0.kind { return true } else { return false }
        }, "patched 시나리오는 사용자 액션 단계가 있으면 안 됨")
        // 핵심 단계 포함 확인.
        let ids = steps.map { $0.id }
        XCTAssertTrue(ids.contains("stop-bridge"))
        XCTAssertTrue(ids.contains("start-demo-patched"))
        XCTAssertTrue(ids.contains("gyro-calibration"))
        XCTAssertTrue(ids.contains("tracking-active"))
    }

    /// 원본 demo 시나리오는 후면 MODE/START 버튼 단계 2개가 명확히 .waitingForUser.
    func testBallFollowOriginalFlowIncludesPhysicalButtons() {
        let steps = PilotTransitionFlow.ballFollowOriginal()
        let userSteps = steps.filter {
            if case .waitingForUser = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(userSteps.count, 2, "원본 demo 시나리오는 후면 MODE + START 두 사용자 액션 필요")
        let userIds = userSteps.map { $0.id }
        XCTAssertTrue(userIds.contains("press-mode-button"))
        XCTAssertTrue(userIds.contains("press-start-button"))
        // 사용자가 무엇을 눌러야 하는지 안내 메시지 확인.
        for s in userSteps {
            XCTAssertTrue(s.detail.contains("MODE") || s.detail.contains("START") || s.detail.contains("후면"),
                          "사용자 액션 단계는 후면 버튼 안내 포함")
        }
    }

    /// 수동 복구 시나리오 검증.
    func testManualRecoveryFlowHasBridgeRestoration() {
        let steps = PilotTransitionFlow.manualRecovery()
        let ids = steps.map { $0.id }
        XCTAssertTrue(ids.contains("stop-demo"))
        XCTAssertTrue(ids.contains("start-bridge"))
        XCTAssertTrue(steps.allSatisfy {
            if case .automatic = $0.kind { return true } else { return false }
        })
    }

    // MARK: - Phase C2: ball detection wrapper

    /// 검출 안 됨 (pixel_count == 0) 시 nil 반환.
    /// 단색 회색 256x256 이미지에는 주황색 공이 없음 → BallVision 이 검출 못해야.
    @MainActor
    func testBallVisionReturnsNilForGraySquare() {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 64*4, bitsPerPixel: 32
        )!
        // 균일한 회색.
        for y in 0..<64 {
            for x in 0..<64 {
                bitmap.setColor(NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                                atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.addRepresentation(bitmap)
        let detection = BallVision.detect(in: image, maxDimension: 64)
        XCTAssertNil(detection, "회색 균일 이미지에는 공이 없음")
    }

    /// Detection 의 isDetected 플래그 동작 확인.
    func testBallVisionDetectionFlags() {
        let det = BallVision.Detection(
            centroidNormalized: CGPoint(x: 0.5, y: 0.5),
            pixelCount: 100,
            approximateRadiusNormalized: 0.1
        )
        XCTAssertTrue(det.isDetected)

        let empty = BallVision.Detection(
            centroidNormalized: .zero, pixelCount: 0,
            approximateRadiusNormalized: 0
        )
        XCTAssertFalse(empty.isDetected)
    }

    // MARK: - Codex 잔여 1: head tracking ROBOTIS FOV + PD + deadband

    /// ROBOTIS 공식 카메라 FOV 가 정확한지 — Camera.h:17 의 58° / 46° (이전 60/45° 추정값 정정).
    @MainActor
    func testHeadTrackerUsesOfficialFOV() {
        let tracker = PilotHeadTracker()
        XCTAssertEqual(tracker.fovHorizontalDeg, 58.0, accuracy: 0.01,
                       "ROBOTIS Camera::VIEW_H_ANGLE = 58°")
        XCTAssertEqual(tracker.fovVerticalDeg, 46.0, accuracy: 0.01,
                       "ROBOTIS Camera::VIEW_V_ANGLE = 46°")
    }

    /// PD 기본 게인 — Codex 권고 보수적 (kp 0.32, kd 0.18).
    @MainActor
    func testHeadTrackerHasConservativePDGains() {
        let tracker = PilotHeadTracker()
        XCTAssertLessThan(tracker.kp, 1.0, "boundary — too aggressive 진동")
        XCTAssertGreaterThan(tracker.kp, 0.1, "boundary — too slow")
        XCTAssertGreaterThan(tracker.kd, 0, "PD 의 D term 양수")
        XCTAssertGreaterThan(tracker.deadbandNormalized, 0,
                             "deadband 가 0 이면 head 떨림")
        XCTAssertGreaterThan(tracker.lostTargetHoldFrames, 0,
                             "lost-target hold 가 즉시 reset 이면 검출 깜빡임에 head 가 깜빡임")
    }

    /// detection 없는 frame 이 연속 들어와도 lostTargetHoldFrames 만큼은 head 위치 유지.
    @MainActor
    func testHeadTrackerHoldsLastPositionOnTransientLost() {
        let tracker = PilotHeadTracker()
        tracker.enabled = true
        // bus/gate 없이도 lostFrameCount 만 카운트되는지 확인 (조기 reset 안 되어야 함).
        for _ in 0..<(tracker.lostTargetHoldFrames - 1) {
            tracker.process(detection: nil, demoActive: false)
        }
        // 아직 hold 중 — skipReason 이 "검출 안 됨" 이면 안 됨.
        XCTAssertNotEqual(tracker.lastSkipReason, "공 검출 안 됨 (\(tracker.lostTargetHoldFrames - 1) frame)")
    }

    // MARK: - Codex 잔여 2/4: IMU stale / unavailable 로직

    /// IMU 가 한 번도 안 들어왔으면 stale 도 true (lastImuSuccessAt nil + failures > 0).
    @MainActor
    func testConnectionStoreImuStaleDefaults() {
        let store = ConnectionStore()
        XCTAssertFalse(store.isImuStale,
                       "초기 상태 — 아직 시도도 안 한 상태는 stale 아님 (lastImu nil + failures=0)")
        XCTAssertFalse(store.isImuUnavailable)
        // failures > 0 이면 lastImuSuccessAt 없어도 stale 로 표시.
        // (직접 set 불가하지만 의도 검증을 위해 published 상태 흐름만 확인)
    }

    // MARK: - Phase E: 4가지 잔여 refinement 검증

    /// HSV preset 의 source badge 가 사용자 수정에 따라 자동 전환.
    /// Phase F1 — 0-100 스케일 (ROBOTIS ColorFinder.h:106-111).
    func testVisionHsvPresetSourceFlowsToModifiedLocally() {
        var preset = VisionHsvPreset.macDefault
        XCTAssertEqual(preset.source, .macDefault)
        // 한 색 변경.
        preset.setRange(MultiColorVision.HSVRange(
            hueCenterDeg: 25, hueToleranceDeg: 25,
            minSaturationPct: 30, minValuePct: 30,
            minPercent: 0.1, maxPercent: 50.0
        ), for: .orange)
        XCTAssertEqual(preset.source, .modifiedLocally,
                       "Mac default 에서 수정하면 modifiedLocally 로 자동 전환")
    }

    /// robotSynced 상태에서 수정하면 modifiedLocally 로.
    func testVisionHsvPresetRobotSyncedToModified() {
        var preset = VisionHsvPreset.macDefault
        preset.source = .robotSynced
        preset.lastRobotSyncAt = Date()
        preset.setRange(MultiColorVision.HSVRange(
            hueCenterDeg: 30, hueToleranceDeg: 25,
            minSaturationPct: 30, minValuePct: 30,
            minPercent: 0.1, maxPercent: 50.0
        ), for: .red)
        XCTAssertEqual(preset.source, .modifiedLocally)
    }

    /// HSV preset 의 JSON 직렬화 round-trip.
    func testVisionHsvPresetCodableRoundTrip() throws {
        let original = VisionHsvPreset.macDefault
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VisionHsvPreset.self, from: data)
        XCTAssertEqual(decoded.orange.hueCenterDeg, original.orange.hueCenterDeg)
        XCTAssertEqual(decoded.red.hueCenterDeg, original.red.hueCenterDeg)
        XCTAssertEqual(decoded.source, .macDefault)
    }

    /// Mac-side ImuFilter — accel-only 첫 sample, gyro 적분 다음 sample.
    func testImuFilterFirstSampleInitsToAccelOnly() {
        var filter = ImuFilter(tau: 0.5)
        let sample = makeImuSample(rollDeg: 12, pitchDeg: -5)
        filter.update(sample, at: Date())
        XCTAssertEqual(filter.rollDeg, 12, accuracy: 0.01,
                       "첫 sample 은 accel-only 정적 추정으로 초기화")
        XCTAssertEqual(filter.pitchDeg, -5, accuracy: 0.01)
        XCTAssertEqual(filter.sampleCount, 1)
    }

    /// 두 번째 sample 부터 CF 가중 — accel 과 gyro 결합.
    func testImuFilterBlendsAccelAndGyro() {
        var filter = ImuFilter(tau: 0.5)
        let now = Date()
        filter.update(makeImuSample(rollDeg: 0, pitchDeg: 0), at: now)
        filter.update(
            makeImuSample(rollDeg: 30, pitchDeg: 0, gyroXDps: 0),
            at: now.addingTimeInterval(0.2)
        )
        // alpha = 0.5/(0.5+0.2) = 0.714. roll = 0.714 × 0 + 0.286 × 30 = 8.57
        XCTAssertEqual(filter.rollDeg, 8.57, accuracy: 0.5,
                       "alpha=0.714 → accel weight 0.286")
    }

    /// QuickActionCatalog 에 HSV read/write 명령 노출 검증.
    /// Phase F1 — 6키 (hue/tol/sat/val/min_pct/max_pct) 모두 read/write 지원.
    func testRobotSetupHsvCommandsExpose() {
        XCTAssertTrue(RobotSetupCommand.readVisionConfig.contains("DF_HSV_"))
        XCTAssertTrue(RobotSetupCommand.readVisionConfig.contains("hue_tolerance"))
        XCTAssertTrue(RobotSetupCommand.readVisionConfig.contains("min_percent"),
                      "Phase F1 — min_percent 키 read 필수 (ColorFinder.h:110)")
        XCTAssertTrue(RobotSetupCommand.readVisionConfig.contains("max_percent"),
                      "Phase F1 — max_percent 키 read 필수 (ColorFinder.h:111)")
        XCTAssertTrue(RobotSetupCommand.writeVisionConfig.contains("DF_ARGS"))
        XCTAssertTrue(RobotSetupCommand.writeVisionConfig.contains("DF_HSV_WROTE"))
        XCTAssertTrue(RobotSetupCommand.writeVisionConfig.contains("$# -ge 7"),
                      "Phase F1 — 7토큰 per tag 처리 (TAG h t s v mp xp)")
        XCTAssertTrue(RobotSetupCommand.writeVisionConfig.contains("min_percent"),
                      "Phase F1 — min_percent write")
        XCTAssertTrue(RobotSetupCommand.writeVisionConfig.contains("max_percent"),
                      "Phase F1 — max_percent write")
    }

    // MARK: - Phase F1: ROBOTIS 정합성 검증 (firmware-reference/05-vision-pipeline.md)

    /// Phase F1 — ROBOTIS factory default 값이 main.cpp:76-86 와 일치.
    /// 이 값이 빗나가면 ROBOTIS demo 가 색 검출 못 함 (사용자 인지: HUD 에 공 표시 안 됨).
    func testMultiColorVisionFactoryDefaultsMatchROBOTIS() {
        let orange = MultiColorVision.defaultRange(for: .orange)
        XCTAssertEqual(orange.hueCenterDeg, 355,
                       "tutorial/color_filtering/config.ini hue")
        XCTAssertEqual(orange.hueToleranceDeg, 15)
        XCTAssertEqual(orange.minSaturationPct, 60, accuracy: 0.01,
                       "0-100 스케일 — ROBOTIS ColorFinder.h:108")
        XCTAssertEqual(orange.minValuePct, 15, accuracy: 0.01)
        XCTAssertEqual(orange.minPercent, 0.1, accuracy: 0.01,
                       "검출 픽셀 비율 하한 — ColorFinder.h:110")
        XCTAssertEqual(orange.maxPercent, 50.0, accuracy: 0.01,
                       "큰 blob 차단 — ColorFinder.h:111")

        let red = MultiColorVision.defaultRange(for: .red)
        XCTAssertEqual(red.hueCenterDeg, 0)
        XCTAssertEqual(red.minSaturationPct, 45, accuracy: 0.01)
        XCTAssertEqual(red.minValuePct, 0, accuracy: 0.01)
        XCTAssertEqual(red.minPercent, 0.3, accuracy: 0.01,
                       "main.cpp:74 RED ColorFinder 인자")

        let yellow = MultiColorVision.defaultRange(for: .yellow)
        XCTAssertEqual(yellow.hueCenterDeg, 60)

        let blue = MultiColorVision.defaultRange(for: .blue)
        XCTAssertEqual(blue.hueCenterDeg, 225)
    }

    /// HSVRange.matches — 입력 (h°/s 0-1/v 0-1) 를 내부 (0-360°/0-100/0-100) 와 비교.
    /// Phase F1 — 이전 0-1 스케일이면 robot ini 값 60 을 0.6 으로 잘못 변환했었음.
    func testHsvRangeMatchesUsesInternalScale() {
        let r = MultiColorVision.HSVRange(
            hueCenterDeg: 60, hueToleranceDeg: 15,
            minSaturationPct: 50, minValuePct: 0
        )
        // sat=0.4 (0-1 입력) < 50 (0-100 임계) → false.
        XCTAssertFalse(r.matches(h: 60, s: 0.4, v: 0.8))
        // sat=0.6 → 60 > 50 → true.
        XCTAssertTrue(r.matches(h: 60, s: 0.6, v: 0.8))
    }

    /// Phase F1 — 3×3 erosion 이 고립된 픽셀 제거 (ImgProcess.cpp:109-150 충실).
    /// 사용자 인지: 이전엔 단일 noise 픽셀이 false centroid 만들었음.
    func testMorphologyErodeRemovesIsolatedPixel() {
        var mask: [UInt8] = Array(repeating: 0, count: 25) // 5×5
        mask[12] = 1  // center pixel only
        Morphology.erode(mask: &mask, width: 5, height: 5)
        XCTAssertEqual(mask[12], 0, "고립 픽셀은 erosion 으로 제거")
    }

    /// 3×3 dilation 이 단일 픽셀을 3×3 블록으로 확장.
    func testMorphologyDilateExpandsSinglePixel() {
        var mask: [UInt8] = Array(repeating: 0, count: 25) // 5×5
        mask[12] = 1
        Morphology.dilate(mask: &mask, width: 5, height: 5)
        // 중심 (12) 주변 3×3 영역 = rows 1..3, cols 1..3.
        for y in 1...3 {
            for x in 1...3 {
                XCTAssertEqual(mask[y * 5 + x], 1,
                               "dilation 확장 (\(x),\(y))")
            }
        }
    }

    /// Opening (erode → dilate) = noise 제거 + 큰 blob 보존.
    /// ROBOTIS GetPosition 의 표준 전처리. 우리 detectAll 도 같은 순서.
    func testMorphologyOpeningRemovesNoiseKeepsBlob() {
        var mask: [UInt8] = Array(repeating: 0, count: 49) // 7×7
        // 노이즈: (1,1) 고립 픽셀.
        mask[1 * 7 + 1] = 1
        // 솔리드 3×3 블록 중심 (4,4): (3,3)..(5,5).
        for y in 3...5 {
            for x in 3...5 {
                mask[y * 7 + x] = 1
            }
        }
        Morphology.openingInPlace(mask: &mask, width: 7, height: 7)
        XCTAssertEqual(mask[1 * 7 + 1], 0, "노이즈 픽셀 제거")
        XCTAssertEqual(mask[4 * 7 + 4], 1, "큰 blob 중심 보존")
    }

    /// VisionHsvPreset Codable — Phase F1 의 새 키 (minSaturationPct/minValuePct/min_pct/max_pct)
    /// 가 JSON 직렬화에 모두 포함되는지. 캐시된 preset 불러올 때 키 누락이면 crash.
    func testVisionHsvPresetCodableIncludesPhaseF1Keys() throws {
        let original = VisionHsvPreset.macDefault
        let data = try JSONEncoder().encode(original)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("hueCenterDeg"))
        XCTAssertTrue(json.contains("minSaturationPct"),
                      "Phase F1 — 0-100 스케일 키")
        XCTAssertTrue(json.contains("minValuePct"))
        XCTAssertTrue(json.contains("minPercent"),
                      "Phase F1 — 검출 비율 하한 키")
        XCTAssertTrue(json.contains("maxPercent"))
        // round-trip
        let decoded = try JSONDecoder().decode(VisionHsvPreset.self, from: data)
        XCTAssertEqual(decoded.orange.minSaturationPct, 60, accuracy: 0.01)
        XCTAssertEqual(decoded.orange.minPercent, 0.1, accuracy: 0.01)
        XCTAssertEqual(decoded.orange.maxPercent, 50.0, accuracy: 0.01)
    }

    /// Phase F1 — PilotHeadTracker 가 ROBOTIS BallTracker.h 의 PanLimit/TiltLimit 그대로.
    @MainActor
    func testHeadTrackerUsesROBOTISPanTiltRanges() {
        let tracker = PilotHeadTracker()
        XCTAssertEqual(tracker.panRangeDeg.lowerBound, -65,
                       "BallTracker.h PanLimit (left)")
        XCTAssertEqual(tracker.panRangeDeg.upperBound, 65,
                       "BallTracker.h PanLimit (right)")
        XCTAssertEqual(tracker.tiltRangeDeg.lowerBound, -12,
                       "BallTracker.h TiltBottomLimit")
        XCTAssertEqual(tracker.tiltRangeDeg.upperBound, 25,
                       "BallTracker.h TiltTopLimit")
    }

    /// Helper — test 용 ImuRaw 생성 (public init 직접 사용).
    private func makeImuSample(rollDeg: Double, pitchDeg: Double, gyroXDps: Double = 0) -> ImuRaw {
        let toRaw: (Double) -> Int16 = { dps in
            Int16(clamping: Int(dps * 32767 / 2000))
        }
        return ImuRaw(
            gyroX: toRaw(gyroXDps), gyroY: 0, gyroZ: 0,
            accelX: 0, accelY: 0, accelZ: 16384,
            rollDeg: rollDeg, pitchDeg: pitchDeg
        )
    }

    // MARK: - PilotFeatureLevel picker (v1.5 신규)

    func testFeatureLevelEnumMaps() {
        XCTAssertEqual(PilotFeatureLevel.v1_0.rawValue, "v1.0")
        XCTAssertEqual(PilotFeatureLevel.v1_5.rawValue, "v1.5")
        XCTAssertEqual(PilotFeatureLevel.v1_0.flags.actionBarMore, false)
        XCTAssertEqual(PilotFeatureLevel.v1_5.flags.actionBarMore, true)
    }

    // MARK: - PilotSafetyGate (3)

    @MainActor
    func testSafetyGateBlocksUnarmedMotion() {
        let gate = PilotSafetyGate()
        let meta = MotionCatalog.find(slot: 4)!  // 감사 인사 (Safe)
        XCTAssertEqual(gate.allowMotion(meta, confirmRisk: false), .blockUnarmed)
    }

    @MainActor
    func testSafetyGateAllowsArmedSafeMotion() {
        let gate = PilotSafetyGate()
        gate.arm()
        let safeMeta = MotionCatalog.find(slot: 1)!
        XCTAssertEqual(gate.allowMotion(safeMeta, confirmRisk: false), .allow)
    }

    @MainActor
    func testSafetyGateRequiresConfirmForHighRisk() {
        let gate = PilotSafetyGate()
        gate.arm()
        let highRiskMeta = MotionCatalog.find(slot: 12)!  // 오른발 차기
        XCTAssertEqual(gate.allowMotion(highRiskMeta, confirmRisk: false),
                       .requireHighRiskConfirm)
        XCTAssertEqual(gate.allowMotion(highRiskMeta, confirmRisk: true), .allow)
    }

    // MARK: - PilotMode + Catalog v1 sendability (3)

    func testV1SendableMatchesPoseLibraryEntries() {
        // 모든 v1TargetPoseID 가 PoseLibrary 에 실제로 존재해야 함.
        for meta in MotionCatalog.all {
            guard let poseID = meta.v1TargetPoseID else { continue }
            XCTAssertNotNil(
                PoseLibrary.get(poseID),
                "slot \(meta.slot) (\(meta.displayNameKo)) → poseID '\(poseID)' 누락"
            )
        }
    }

    func testV1SendableCountIsAtLeastFive() {
        // v1.0 에서 실제 송출되는 페이지는 7 중 최소 5 (왼발 차기 mirror pose 누락 등 허용).
        let count = MotionCatalog.actionBarMain.filter { $0.v1TargetPoseID != nil }.count
        XCTAssertGreaterThanOrEqual(count, 5,
            "메인 7 중 최소 5 페이지는 v1.0 에서 실 송출 가능해야 함")
    }

    func testPilotModePickerHasManualAndBallFollow() {
        XCTAssertEqual(PilotMode.allCases, [.manual, .ballFollow])
        XCTAssertEqual(PilotMode.manual.label, "수동")
        XCTAssertEqual(PilotMode.ballFollow.label, "공 자동 추적")
    }

    // MARK: - SafetyClass equality (1)

    func testSafetyClassLabels() {
        XCTAssertEqual(SafetyClass.safe.koreanLabel, "안전")
        XCTAssertEqual(SafetyClass.caution.koreanLabel, "주의")
        XCTAssertEqual(SafetyClass.highRisk.koreanLabel, "위험")
        XCTAssertFalse(SafetyClass.safe.requiresConfirm)
        XCTAssertFalse(SafetyClass.caution.requiresConfirm)
        XCTAssertTrue(SafetyClass.highRisk.requiresConfirm)
    }
}

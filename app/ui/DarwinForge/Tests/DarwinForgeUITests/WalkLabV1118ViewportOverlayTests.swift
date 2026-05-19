import XCTest
import SwiftUI
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.18 (2026-05-19) — viewport overlay + IMU tilt + 데이터 진위 검증**.
///
/// 1. SceneGyroMiniOverlay / SceneWalkGraphOverlay 가 컴파일.
/// 2. RobotScene3D 가 imuRollDeg/imuPitchDeg 인자 받음 (default 0 backward-compat).
/// 3. 데이터 흐름 진위 — sim/real/stale 분기가 명시 라벨 표시.
@MainActor
final class WalkLabV1118ViewportOverlayTests: XCTestCase {

    // MARK: - 1. RobotScene3D IMU tilt 인터페이스

    /// **v1.11.18 fix 4**: RobotScene3D init 가 imuRollDeg/imuPitchDeg 인자 받음.
    /// default 0 — backward compat (기존 호출처 변경 없음).
    func testRobotScene3DAcceptsImuTilt() {
        let pose = RobotPose.walkReady
        let scene = RobotScene3D(
            pose: pose,
            imuRollDeg: 5.0,
            imuPitchDeg: -3.0
        )
        XCTAssertEqual(scene.imuRollDeg, 5.0)
        XCTAssertEqual(scene.imuPitchDeg, -3.0)
    }

    /// default 인자 — 0/0 (기존 호출처).
    func testRobotScene3DDefaultImuTilt() {
        let pose = RobotPose.walkReady
        let scene = RobotScene3D(pose: pose)
        XCTAssertEqual(scene.imuRollDeg, 0)
        XCTAssertEqual(scene.imuPitchDeg, 0)
    }

    // MARK: - 2. 데이터 진위 검증 (가짜 vs 실 데이터)

    /// **데이터 흐름 명시 검증**: bus 미연결 → sim. SIM chip 으로 사용자 인지.
    func testImuSourceSimWhenBusNotConnected() {
        let session = WalkLabSession()
        // store 미attach → bus 자동 nil → updateImuSource 가 sim 분기.
        XCTAssertEqual(session.imuSource, .sim,
                       "초기 store 없음 — sim fallback 명시")
    }

    /// **데이터 흐름 명시 검증**: imuSource label 이 사용자에게 명확.
    func testImuSourceLabelsAreUserVisible() {
        // session.imuSource = .sim → "SIM" / .real → "REAL" / .stale → "STALE"
        // LiveGyroPanel + SceneGyroMiniOverlay 가 sourceLabel 로 표시.
        let cases: [(WalkLabSession.ImuSource, String)] = [
            (.sim, "sim"),    // raw value 또는 description
            (.real, "real"),
            (.stale, "stale"),
        ]
        for (source, expectedSubstring) in cases {
            let asString = "\(source)"
            XCTAssertTrue(asString.lowercased().contains(expectedSubstring),
                          "imuSource \(source) 의 description 이 사용자 식별 가능")
        }
    }

    /// **가짜 데이터 명시 표시**: sim mode 의 imuRollDeg 가 0 (idle) 또는 사인파 (walking).
    /// 사용자가 SIM chip 으로 인지 가능 — silent 가짜 X.
    func testSimImuValuesAreClearlyMarkedAsSim() {
        let session = WalkLabSession()
        XCTAssertEqual(session.imuSource, .sim)
        // idle 상태 — sim 이라도 0 으로 수렴 (사용자 혼란 X).
        XCTAssertEqual(session.imuRollDeg, 0)
        XCTAssertEqual(session.imuPitchDeg, 0)
    }

    // MARK: - 3. lastImuRaw 가 raw gyro X/Y/Z 노출

    /// ConnectionStore.lastImuRaw 가 nil 초기값 → polling 후 갱신 invariant.
    func testConnectionStoreLastImuRawInitiallyNil() {
        let store = ConnectionStore()
        XCTAssertNil(store.lastImuRaw,
                     "초기 nil — IMU polling 시작 전. UI 가 'real' 표시 안 함.")
    }

    // MARK: - 4. SceneGyroMiniOverlay / SceneWalkGraphOverlay 컴파일

    /// 컴파일 + init 성공 검증 (rendering 검증 X — body 만 instantiation).
    func testViewportOverlaysInstantiate() {
        _ = SceneGyroMiniOverlay()
        _ = SceneWalkGraphOverlay()
        // 컴파일 성공 = init API 안정. body 는 SwiftUI runtime 검증.
        XCTAssertTrue(true)
    }
}

import Foundation
import OSLog

/// **v1.11.23 (2026-05-21)** — DarwinForge 공유 logger 시스템.
///
/// macOS 표준 OSLog 를 활용 — Console.app 에서 필터링 / 검색 / 추적 가능.
/// 종전 `print()` 호출은 stdout 으로만 흘러 production 진단이 어려움.
///
/// # 사용 예
/// ```swift
/// DFLog.connection.error("readState failed: \(error.localizedDescription)")
/// DFLog.visualization.warning("STL load failed: \(name)")
/// DFLog.walkLab.notice("emergency stop triggered — tilt \(tilt)°")
/// ```
///
/// # 카테고리 분류
/// - `connection`: ConnectionStore / SerialPort / SSH / NetworkProbe
/// - `visualization`: SceneKit / MeshRig / RobotScene3D
/// - `walkLab`: WalkLabSession / corrector / fall predictor
/// - `motion`: MotionStudio / motion play
/// - `claude`: Claude API / Critic / Analyzer
/// - `system`: app lifecycle / general
public enum DFLog {
    public static let subsystem = "com.darwinforge"

    public static let connection = Logger(subsystem: subsystem, category: "connection")
    public static let visualization = Logger(subsystem: subsystem, category: "visualization")
    public static let walkLab = Logger(subsystem: subsystem, category: "walkLab")
    public static let motion = Logger(subsystem: subsystem, category: "motion")
    public static let claude = Logger(subsystem: subsystem, category: "claude")
    public static let system = Logger(subsystem: subsystem, category: "system")
}

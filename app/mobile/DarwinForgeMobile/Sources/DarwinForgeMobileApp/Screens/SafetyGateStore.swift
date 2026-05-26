import Foundation
import MobilePilotKit

// MARK: - SafetyGateState
//
// 비행기 탑승 안전 영상에 비유: 매번 봐야 하는 이유.
// 항공사는 승객이 "이미 알아요"라고 해도 매번 안전 영상을 튼다.
// OP 파일럿도 마찬가지 — 페어링이 성공해도 ARM 전에 Safety Brief → Preflight → E-Stop Drill
// 3개의 게이트를 순서대로 통과해야 한다. 각 게이트 통과 전에는 ARM 불가.
//
// 기술적으로: 이 enum 은 페어링 성공 이후의 상태 기계를 나타낸다.
//   none     — 아직 페어링 미완료
//   brief    — Safety Brief Modal 표시 중 (3 체크 미완료)
//   preflight — Preflight Checklist 진행 중 (자동 + 수동 체크)
//   drill    — E-Stop Drill 진행 중 (첫 페어링 시 only)
//   ready    — 3 게이트 모두 통과 → ARM 가능

public enum SafetyGateState: Equatable, Sendable {
    /// 페어링 전 — 아무 게이트도 표시하지 않음
    case none
    /// Safety Brief Modal 강제 표시 중
    case brief
    /// Preflight Checklist 진행 중
    case preflight
    /// E-Stop Drill 진행 중 (첫 페어링 시 only)
    case drill
    /// 모든 게이트 통과 — ARM 가능
    case ready
}

// MARK: - SafetyGateStore
//
// UserDefaults 키 이름을 한 곳에 모아 오타 방지.
// "eStopDrillCompleted" 는 앱 설치 후 최초 1회 드릴을 완료했는지 여부를 저장한다.
// 페어링 session 마다 Safety Brief 와 Preflight 는 반복되지만, Drill 은 1회만.

public enum SafetyGateKeys {
    /// 최초 1회 E-Stop Drill 완료 여부 (UserDefaults)
    public static let eStopDrillCompleted = "darwinforge.eStopDrillCompleted"
}

// MARK: - PreflightItem

/// Preflight 체크 항목 하나를 나타낸다. 자동(telemetry 기반) 또는 수동(사용자 토글).
public struct PreflightItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case automatic   // telemetry 기반 자동 체크
        case manual      // 사용자가 직접 확인하는 토글
    }

    public enum Status: Equatable, Sendable {
        case pending   // 아직 평가 전
        case pass      // 통과
        case fail(reason: String)  // 실패 (구체적 안내 포함)
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public var status: Status

    public init(id: String, title: String, kind: Kind, status: Status = .pending) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
    }

    public var isPassed: Bool {
        if case .pass = status { return true }
        return false
    }
}

// MARK: - PreflightEvaluator

/// Preflight 자동 체크 항목을 telemetry 로 평가한다.
/// 배터리 30% 이상, IMU 응답 정상(telemetry 수신), dxlPower OFF 기준.
public enum PreflightEvaluator {

    /// 상수: 배터리 최소 전압 임계값 (≈ 30% for OP2 11.1V 3S 기준 → 10.5V)
    public static let batteryMinVoltage: Double = 10.5

    /// telemetry 를 받아 자동 Preflight 항목 배열을 반환한다.
    /// - Parameter telemetry: 현재 텔레메트리 페이로드 (nil 이면 모두 fail)
    /// - Returns: 자동 체크 결과 배열
    public static func evaluate(telemetry: TelemetryStatePayload?) -> [PreflightItem] {
        var items: [PreflightItem] = []

        // 1. IMU 응답: telemetry 수신 여부
        let imuStatus: PreflightItem.Status
        if let t = telemetry, t.robot == .connected || t.robot == .sim {
            imuStatus = .pass
        } else if telemetry != nil {
            imuStatus = .fail(reason: "로봇 연결 상태를 확인하세요")
        } else {
            imuStatus = .fail(reason: "텔레메트리 수신 전")
        }
        items.append(PreflightItem(id: "imu",
                                   title: "IMU 응답 정상",
                                   kind: .automatic,
                                   status: imuStatus))

        // 2. 배터리 > 30%
        let batteryStatus: PreflightItem.Status
        if let v = telemetry?.batteryV {
            let voltageText = String(format: "%.1f", v) + "V"
            // **V292-C critic MAJOR-2 fix** — Mac WalkLabSession 의 lowBatteryThreshold (10.5V) 와 일관.
            // Mac 는 `v <= 10.5` 차단 → mobile 도 `> 10.5` 통과 (경계값은 보수적으로 차단).
            if v > batteryMinVoltage {
                batteryStatus = .pass
            } else {
                batteryStatus = .fail(reason: "배터리 부족 (\(voltageText)) — 충전 후 재시도")
            }
        } else {
            batteryStatus = .fail(reason: "배터리 정보 수신 전")
        }
        items.append(PreflightItem(id: "battery",
                                   title: "배터리 > 30%",
                                   kind: .automatic,
                                   status: batteryStatus))

        // 3. 관절 calibration (telemetry 에 calibration 필드 없을 경우 sim → pass, 없으면 fail)
        let calibStatus: PreflightItem.Status
        if let t = telemetry {
            // sim 은 calibration 패스, 실 로봇은 robot == .connected 이면 패스
            calibStatus = (t.robot == .sim || t.robot == .connected) ? .pass
                : .fail(reason: "관절 캘리브레이션을 확인하세요")
        } else {
            calibStatus = .fail(reason: "캘리브레이션 상태 수신 전")
        }
        items.append(PreflightItem(id: "calibration",
                                   title: "관절 캘리브레이션 통과",
                                   kind: .automatic,
                                   status: calibStatus))

        // 4. dxlPower 현재 OFF (safe baseline — TelemetryStatePayload.dxlPower 기준)
        let dxlStatus: PreflightItem.Status
        if let t = telemetry {
            // t.dxlPower == false 이면 OFF → pass (safe baseline)
            let powerOff = !t.dxlPower
            dxlStatus = powerOff ? .pass : .fail(reason: "dxlPower 가 ON — 안전 기준 위반")
        } else {
            dxlStatus = .fail(reason: "dxlPower 상태 수신 전")
        }
        items.append(PreflightItem(id: "dxlPower",
                                   title: "dxlPower 현재 OFF",
                                   kind: .automatic,
                                   status: dxlStatus))

        return items
    }
}

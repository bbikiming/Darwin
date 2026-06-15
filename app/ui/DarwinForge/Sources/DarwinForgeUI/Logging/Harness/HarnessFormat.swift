import Foundation

// MARK: - HarnessFormat (V289-4, 2026-05-25)
//
// NIST SP 811 §7.2 (숫자·단위 1칸 공백) + §7.5 (고정 소수점)
// ISO 80000-1 §7.3.1 (부호 항상 표시 — 양수도 +)
// Nielsen #9 (진단 가능 에러 메시지)
//
// 비유: 계기판 문자판 공장 — 모든 게이지가 같은 폰트·자릿수 규격으로 출력되도록
// 단 하나의 공장에서 찍어낸다. 화면마다 다른 소수점 자리를 쓰면 운영자가 혼란.
//
// 규칙 요약:
//   - gyro  : 부호 항상 + 앞자리 패딩 없음, 소수 1자리, "°/s" (공백)
//     (V289-7 critic MINOR-2 — 기존 코드베이스 일관성 위해 deg/s → °/s)
//   - 각도   : 소수 1자리, "°" (붙임 — NIST 예외)
//   - 전압   : 소수 2자리, "V" (공백)
//   - 온도   : 소수 1자리, "°C" (공백)
//   - 통신지연: 소수 1자리, "ms" (공백)
//   - 패킷손실: 소수 1자리, "%" (공백)
//
// 상태 라벨: statusLabel(_:) 참조 — 한글 사전.
//
// 빈 상태 / 에러 메시지: EmptyStateMessage / ErrorTemplate 참조.

// MARK: - Sensor value formatters

enum HarnessFormat {

    // MARK: Gyro — ISO 80000 §7.3.1 부호 항상 표시, 소수 1자리
    /// `+123.4 °/s` 또는 `−12.3 °/s` (V289-7 critic MINOR-2)
    static func formatGyro(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.1f", abs(value))) °/s"
    }

    // MARK: 각도 (roll/pitch) — 소수 1자리, °는 숫자에 붙임 (NIST 예외)
    /// `−12.7°` 또는 `+3.2°`
    static func formatAngle(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.1f", abs(value)))°"
    }

    // MARK: 전압 — 소수 2자리, 단위 공백
    /// `11.85 V`
    static func formatVoltage(_ value: Double) -> String {
        return String(format: "%.2f V", value)
    }

    // MARK: 온도 — 소수 1자리, 단위 공백
    /// `42.3 °C`
    static func formatTemp(_ value: Double) -> String {
        return String(format: "%.1f °C", value)
    }

    // MARK: 통신 지연 — 소수 1자리, 단위 공백
    /// `8.2 ms`
    static func formatLatency(_ value: Double) -> String {
        return String(format: "%.1f ms", value)
    }

    // MARK: 패킷 손실 — 소수 1자리, 단위 공백
    /// `0.3 %`
    static func formatPacketLoss(_ value: Double) -> String {
        return String(format: "%.1f %%", value)
    }

    // MARK: - 상태 라벨 사전 (한글 Apple HIG 준수)

    enum ConnectionStatus: String {
        case connected      = "연결됨"
        case disconnected   = "연결 끊김"
        case error          = "오류"
        case calibrating    = "보정 중"
        case initializing   = "초기화 중"
    }

    /// stale 상태 라벨: "갱신 지연 2.3초 전"
    static func staleLabel(secondsAgo: Double) -> String {
        return String(format: "갱신 지연 %.1f초 전", secondsAgo)
    }

    /// 일반 갱신 시각: "갱신 0.4초 전" (stale 아닐 때)
    static func freshLabel(secondsAgo: Double) -> String {
        if secondsAgo < 1.0 { return "방금 갱신" }
        return String(format: "갱신 %.1f초 전", secondsAgo)
    }

    // MARK: - 빈 상태 / 에러 메시지 5템플릿 (Nielsen #9)

    enum EmptyState {
        /// 데이터 없음: 센서 전원 점검 안내
        static let noSensorData = "센서 데이터 없음 — IMU 전원을 확인하세요"

        /// 이벤트 없음 (필터 적용 시): 구체적 검색어 안내
        static func noEvents(filter: String) -> String {
            if filter.isEmpty {
                return "이벤트 없음 — Harness 기록이 활성화되어 있는지 확인하세요"
            }
            return "이벤트 없음 — 검색어 [\(filter)] 또는 필터를 지우세요"
        }

        /// 이벤트 없음 (필터 없음)
        static let noEventsPlain = "이벤트 없음 — Harness 기록이 활성화되어 있는지 확인하세요"

        /// 세션 없음 (V289-7 critic MINOR-6 — Nielsen #9 what/why/next 3요소)
        static let noSessions = "저장된 세션 없음 — Harness 가 활성화된 상태에서 walk/teach 를 시작하세요"
    }

    enum ErrorMessage {
        /// IMU 응답 없음 (포트 + 재시도 표시)
        static func imuNoResponse(port: String, retry: Int, maxRetry: Int) -> String {
            return "IMU 응답 없음 (포트 \(port), 재시도 \(retry)/\(maxRetry))"
        }

        /// 배터리 임계 미만
        static func batteryBelowThreshold(voltage: Double, threshold: Double) -> String {
            return "배터리 \(String(format: "%.2f", voltage)) V — 임계(\(String(format: "%.1f", threshold)) V) 미만, 즉시 충전 필요"
        }

        /// DXL bus timeout
        static func dxlBusTimeout(secondsAgo: Double) -> String {
            return String(format: "DXL bus timeout · 마지막 응답 %.1f초 전", secondsAgo)
        }

        /// 자이로 미보정
        static let gyroNotCalibrated = "자이로 미보정 — Walk 시작 전 보정 실행 필요"
    }
}

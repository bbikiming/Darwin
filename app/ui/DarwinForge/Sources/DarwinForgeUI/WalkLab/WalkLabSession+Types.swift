import Foundation
import ForgeCore

/// 2026-05-17 T3.1 partial split: WalkLabSession 1599 LOC god object 의 public
/// type definitions 만 별도 file 로 추출.
/// 회귀 위험 0 — nested type identity 그대로 (`WalkLabSession.ImuSource` 등),
/// access modifier 변경 0, 호출 site 영향 0.
///
/// 본 file 의 type 들:
/// - `MotorTempSource` — 모터 온도 데이터 출처 (sim/real/stale)
/// - `ImuSource` — IMU 데이터 출처 (sim/real/stale)
/// - `BalanceState` — 5단계 안전 상태 (normal/caution/warning/danger/emergency)
/// - `SafetySample` — 시계열 안전 sample (sparkline 차트 source)
/// - `SafetyEvent` — 안전 이벤트 로그 row + Kind enum
/// - `WalkCycleResult` — 보행 cycle 종료 결과 + EndReason enum
/// - `WalkPreflightFailure` — preflight 실패 사유 + Cause enum
///
/// 향후 dedicated sprint 에서 `WalkLabSession+WalkCycle.swift`,
/// `WalkLabSession+IMU.swift`, `WalkLabSession+Safety.swift` 로 함수 분리 예정.
/// 통합 테스트 30+ 케이스 선결 (T3.1 deferral 문서 참조).

extension WalkLabSession {
    /// 모터 온도 데이터 출처 — Stage 1 분석 후 추가 (2026-05-16).
    public enum MotorTempSource: Equatable, Sendable {
        /// 실 robot 미연결 또는 telemetry 미수신 — `updateSimThermal` 모델 값.
        case sim
        /// 실 robot 연결 + telemetry fresh — `lastTelemetry.joints` 의 max 사용.
        case real
        /// 실 robot 연결 됐으나 telemetry 5초+ 지연 — 마지막 값 hold.
        case stale

        public var label: String {
            switch self {
            case .sim:   return "시뮬"
            case .real:  return "실 모터"
            case .stale: return "지연"
            }
        }
    }

    /// IMU 데이터 출처 — Stage 1 wire-up 이후 도입.
    public enum ImuSource: Equatable, Sendable {
        /// 실 robot 미연결 또는 테스트 — `updateSimIMU` 모델 값.
        case sim
        /// 실 robot 연결 + `ConnectionStore.imuFilter` 5Hz polling 값.
        case real
        /// 실 robot 연결 됐으나 IMU 갱신 5초+ 지연 — 마지막 값 hold.
        case stale

        public var label: String {
            switch self {
            case .sim:   return "시뮬"
            case .real:  return "실 IMU"
            case .stale: return "IMU 지연"
            }
        }
    }

    /// 안전 상태 — `|max(|roll|, |pitch|)|` 기준 5단계.
    ///
    /// **임계** (deg):
    /// | 상태 | 임계 | 동작 |
    /// |---|---|---|
    /// | `.normal` | < 15° | 정상 |
    /// | `.caution` | 15-22° | UI 경고만 |
    /// | `.warning` | 22-28° | 보행 속도 70% 자동 감속 |
    /// | `.danger` | 28-30° | 자세 동결 (cycle 일시 정지) |
    /// | `.emergency` | ≥ 30° | 토크 OFF + walkReady 복귀 (기존 L3) |
    public enum BalanceState: Int, Comparable, Equatable, Sendable {
        case normal = 0, caution, warning, danger, emergency

        public static func < (l: BalanceState, r: BalanceState) -> Bool {
            l.rawValue < r.rawValue
        }

        /// IMU |max| 각도로부터 상태 결정.
        public static func from(maxTilt: Double) -> BalanceState {
            if maxTilt >= 30 { return .emergency }
            if maxTilt >= 28 { return .danger }
            if maxTilt >= 22 { return .warning }
            if maxTilt >= 15 { return .caution }
            return .normal
        }

        public var label: String {
            switch self {
            case .normal:    return "정상"
            case .caution:   return "주의"
            case .warning:   return "경고"
            case .danger:    return "위험"
            case .emergency: return "비상"
            }
        }

        /// 보행 속도 배수 (Stage 2 자동 감속).
        public var speedScale: Double {
            switch self {
            case .normal, .caution: return 1.0
            case .warning:          return 0.7  // 70% 감속
            case .danger:           return 0.0  // 자세 동결
            case .emergency:        return 0.0  // 정지
            }
        }
    }

    /// 안전 상태 한 시점 스냅샷 — sparkline 차트 source.
    public struct SafetySample: Equatable, Sendable {
        public let timestamp: Date
        public let rollDeg: Double
        public let pitchDeg: Double
        public let predictionScore: Double
        public let balanceState: BalanceState
        /// 4 관절 corrector delta 의 최대 절댓값 (deg). 0 = corrector off 또는 보정 없음.
        public let correctorMaxDelta: Double
    }

    /// 안전 이벤트 한 건 — 이벤트 로그 row.
    public struct SafetyEvent: Identifiable, Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case sessionStart
            case sessionStop
            case stateChange
            case emergencyTriggered
            case predictorRecommend
            case correctorOn
            case correctorOff
            case rampComplete
            case imuSourceChange
            /// 모터 온도 출처 변경 — 실 robot 연결 시 sim → real 등.
            /// 2026-05-16: imuSourceChange 와 분리 (이전 버그: 같은 Kind 재사용 →
            /// 이벤트 로그 아이콘이 gyroscope 로 표시되어 모터 온도 변경이 IMU
            /// 변경처럼 보임).
            case motorTempSourceChange
            case thermalAlarm
            case preflightFailure
        }
        public let id = UUID()
        public let timestamp: Date
        public let kind: Kind
        public let message: String
    }

    /// 보행 cycle 의 진행 결과 — runWalkCycle 가 반환.
    public struct WalkCycleResult: Equatable, Sendable {
        public enum EndReason: Equatable, Sendable {
            case completedMaxDuration
            case userCancelled
            case lowerBodyWriteFailure
            case bulkWriteFailure
            /// 2026-05-17 chaos audit #1 fix: cycle 중 store.bus 가 nil 로 변경됨
            /// (USB disconnect / 네트워크 끊김 / forceDisconnectWithError 발동).
            /// 종전엔 walkCycleTask 가 dead bus 에 계속 송출 → bulkWriteFailure 누적
            /// 까지 부분 정지. 신규: 명시적 abort + 명확한 사용자 메시지.
            case busDisconnected
        }
        public let reason: EndReason
        public let stepsExecuted: Int
        public let speedWriteFailures: Int
        public let positionWriteFailures: Int
        public let lowerBodyPositionFails: [JointID]
        public let sampleError: String?

        public var userMessage: String {
            switch reason {
            case .completedMaxDuration:
                return "보행 종료 — 시간 도달 (\(stepsExecuted) step)"
            case .userCancelled:
                return "보행 취소 — 사용자/정지 신호 (\(stepsExecuted) step)"
            case .lowerBodyWriteFailure:
                let names = lowerBodyPositionFails.prefix(3).map { $0.name }.joined(separator: ", ")
                let suffix = sampleError.map { " · 예: \($0)" } ?? ""
                return "보행 중단 — 하체 위치쓰기 \(lowerBodyPositionFails.count)개 실패 (\(names)). 균형 위험\(suffix)"
            case .bulkWriteFailure:
                let suffix = sampleError.map { " · 예: \($0)" } ?? ""
                return "보행 중단 — 통신 절반 이상 실패 (위치 \(positionWriteFailures)·속도 \(speedWriteFailures))\(suffix)"
            case .busDisconnected:
                return "보행 중단 — 로봇 연결 끊김 (\(stepsExecuted) step 후). 재연결 후 다시 시작해 주세요"
            }
        }

        public var isSuccess: Bool {
            switch reason {
            case .completedMaxDuration, .userCancelled: return true
            case .lowerBodyWriteFailure, .bulkWriteFailure, .busDisconnected: return false
            }
        }
    }

    /// 보행 cycle 시작 전 preflight 실패 사유.
    public struct WalkPreflightFailure: Equatable, Sendable {
        public enum Cause: Equatable, Sendable {
            case noConnection
            case cradleNotConfirmed
            case dxlPowerFailed(String)
            case lowerBodyTorqueFailed([JointID])
            case bulkTorqueFailed(failedCount: Int, total: Int)
            /// 2026-05-17 사용자 보고 critical fix: caution 등급 preset (fastWalk/turn*)
            /// 은 정적 plan + IMU balance 미활성 시 실 robot 낙상 위험. balanceCorrection
            /// 활성화 요구.
            case balanceCorrectorRequiredForCautionPreset(presetLabel: String)
        }
        public let cause: Cause
        public var userMessage: String {
            switch cause {
            case .noConnection:
                return "ℹ️ 시뮬 모드 — 로봇 미연결 (보행 cycle 미실행)"
            case .cradleNotConfirmed:
                return "⚠️ cradle 미확인 — 정비 스탠드 거치 후 다시 시도"
            case .dxlPowerFailed(let e):
                return "🛑 모터 전원 ON 실패 — \(e)"
            case .lowerBodyTorqueFailed(let joints):
                let names = joints.prefix(3).map { $0.name }.joined(separator: ", ")
                return "🛑 보행 시작 차단 — 하체 토크 \(joints.count)개 실패 (\(names)). USB·전원·ID 확인"
            case .bulkTorqueFailed(let f, let t):
                return "🛑 보행 시작 차단 — 상체 토크 \(f)/\(t) 실패. 통신 점검"
            case .balanceCorrectorRequiredForCautionPreset(let label):
                return "🛑 '\(label)' 시작 차단 — '자세 보정' 토글을 먼저 켜주세요 (IMU 기반 균형 보정 없이 실행 시 낙상 위험)"
            }
        }
    }
}

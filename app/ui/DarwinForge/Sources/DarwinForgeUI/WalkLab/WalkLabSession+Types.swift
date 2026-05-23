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
    /// **v1.11.25 (2026-05-21) audit log-G** — emergencyStop 호출 출처.
    ///
    /// 종전: 모든 trigger 가 Harness 의 actor=.user 로 기록 → 사용자 클릭 vs 자동 trigger
    /// (balance lost / thermal / voltage) 발생률 통계 추출 불가.
    ///
    /// **v1.21.2 사이클 67 — 코덱스 MEDIUM-3 fix**: `.unknown` fallback case 추가.
    /// `WalkPreflightFailure.emergencyActive(trigger:)` payload 가 trigger 정보를 보존
    /// — `_lastEmergencyTrigger` 가 nil 인 edge case (init 직후 race) 에 안전한 fallback.
    public enum EmergencyTrigger: String, Sendable, Codable {
        /// 사용자 비상정지 버튼 / ESC 키.
        case userClick
        /// L3 hard gate — IMU tilt ≥ 50° 3 sample 연속.
        case balanceLostL3
        /// L4 — 모터 평균 온도 ≥ 60°C.
        case thermalOverheat
        /// L0 — battery voltage < 9.5V 지속.
        case voltageDroop
        /// fall predictor 가 recommend emergency rising-edge.
        case fallPredictorRecommend
        /// 외부 emergency (Pilot ESC, RootView 전역 단축키 등).
        case externalEStop
        /// **사이클 67 신규** — emergency 활성 상태 진입은 알지만 trigger 출처 미상.
        /// 보통 `_lastEmergencyTrigger` race 또는 외부 상태 직접 set 시.
        case unknown

        /// Harness telemetry actor — `.user` 만 사용자, 그 외는 자동.
        public var harnessActor: TelemetryActor {
            switch self {
            case .userClick, .externalEStop: return .user
            case .balanceLostL3, .thermalOverheat, .voltageDroop, .fallPredictorRecommend, .unknown:
                return .robot
            }
        }

        /// **사이클 67 신규** — 사용자 메시지용 한국어 라벨.
        /// `.emergencyActive` cause 의 userMessage 가 trigger 출처를 명시 노출.
        public var koreanLabel: String {
            switch self {
            case .userClick:              return "사용자 정지"
            case .balanceLostL3:          return "L3 균형 손실"
            case .thermalOverheat:        return "모터 과열"
            case .voltageDroop:           return "전압 droop"
            case .fallPredictorRecommend: return "낙상 예측"
            case .externalEStop:          return "외부 E-Stop"
            case .unknown:                return "출처 미상"
            }
        }
    }

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
    /// **v1.8 (2026-05-17) 임계 상향 — 사용자 보고 "조금만 기울어도 중단" false-positive**.
    /// 종전 15/22/28/30° 는 ROBOTIS Walking.cpp 의 FALLEN_F/B_LIMIT (raw 390/580, ~45-50°)
    /// 대비 너무 보수적 → 일반 보행의 정상 흔들림 (5-15°) 도 caution → warning false trigger.
    ///
    /// **신규 임계 (ROBOTIS 정신 + 안전 buffer)**:
    /// | 상태 | 임계 | 동작 |
    /// |---|---|---|
    /// | `.normal` | < 25° | 정상 (정상 보행 흔들림 cover) |
    /// | `.caution` | 25-35° | UI 경고만 |
    /// | `.warning` | 35-45° | 보행 속도 70% 자동 감속 |
    /// | `.danger` | 45-50° | 자세 동결 |
    /// | `.emergency` | ≥ 50° | 토크 OFF + walkReady (ROBOTIS FALLEN 수준) |
    public enum BalanceState: Int, Comparable, Equatable, Sendable, Codable {
        case normal = 0, caution, warning, danger, emergency

        public static func < (l: BalanceState, r: BalanceState) -> Bool {
            l.rawValue < r.rawValue
        }

        /// IMU |max| 각도로부터 상태 결정 (v1.8 상향).
        public static func from(maxTilt: Double) -> BalanceState {
            if maxTilt >= 50 { return .emergency }
            if maxTilt >= 45 { return .danger }
            if maxTilt >= 35 { return .warning }
            if maxTilt >= 25 { return .caution }
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
    public struct SafetySample: Equatable, Sendable, Codable {
        public let timestamp: Date
        public let rollDeg: Double
        public let pitchDeg: Double
        public let predictionScore: Double
        public let balanceState: BalanceState
        /// 4 관절 corrector delta 의 최대 절댓값 (deg). 0 = corrector off 또는 보정 없음.
        public let correctorMaxDelta: Double
    }

    /// **v1.14.8 (2026-05-21) perf #6**: 정규화 (convention 적용) 된 sample.
    /// 종전: FallPreventionMonitor.timeSeriesRow 가 매 body 재평가 마다 250 sample 을
    ///       loop 돌며 ImuAttitudeDisplayMapping.normalizeConvention 호출 (750+ atan/asin).
    ///       SwiftUI body 가 10Hz tick 마다 재평가되면 7,500+ 회/초 → main actor 부담.
    /// 신규: session 안에서 sample append 시 1회 정규화 → 캐시. View 는 read only.
    public struct NormalizedSafetySample: Equatable, Sendable, Identifiable {
        public let timestamp: Date
        /// convention 정규화 + NaN/Inf guard 적용된 roll (deg).
        public let rollDeg: Double
        /// convention 정규화 + NaN/Inf guard 적용된 pitch (deg).
        public let pitchDeg: Double
        public let predictionScore: Double

        public var id: Date { timestamp }
    }

    /// 안전 이벤트 한 건 — 이벤트 로그 row.
    public struct SafetyEvent: Identifiable, Equatable, Sendable, Codable {
        public enum Kind: String, Equatable, Sendable, Codable {
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
            // v1.11.25 audit log-D — kind 재사용 제거를 위한 dedicated case.
            /// 보행 엔진 전환 (Mac sparse ↔ ROBOTIS onboard).
            case engineSwitched
            /// A/B 실험 적용 (applyExperimentChange).
            case experimentApplied
            /// A/B 실험 rollback.
            case experimentRolledBack
            /// AutoTuner 가 권고 자동 적용.
            case autoTunerApplied
            /// L0 voltage droop trigger (전압 임계 도달).
            case voltageDroop
            /// 사용자가 onboard 수동 송출 성공.
            case manualSendSucceeded
            /// **v1.20.12 사이클 18** — 사용자 emergency recovery (flag clear, walking 미시작).
            case recovery
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
                return "보행 중단 — 하체 목표 위치 전송 \(lowerBodyPositionFails.count)개 실패 (\(names)). 균형 위험\(suffix)"
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
    public struct WalkPreflightFailure: Equatable, Sendable, Codable {
        public enum Cause: Equatable, Sendable, Codable {
            case noConnection
            case cradleNotConfirmed
            case dxlPowerFailed(String)
            case lowerBodyTorqueFailed([JointID])
            case bulkTorqueFailed(failedCount: Int, total: Int)
            /// 2026-05-17 사용자 보고 critical fix: caution 등급 preset (fastWalk/turn*)
            /// 은 정적 plan + IMU balance 미활성 시 실 robot 낙상 위험. balanceCorrection
            /// 활성화 요구.
            case balanceCorrectorRequiredForCautionPreset(presetLabel: String)
            // v1.11.22.1 (Codex LOW fix): IMU 차단 사유별 명세화 — 사후 진단 의미 보존.
            case imuUnavailable
            case imuStale
            case imuPlausibilityFailed(String)
            // v1.11.24 (2026-05-20 audit P0-1, P0-2) — 상태 일관성 가드:
            // 다른 cycle 활성 상태에서 새 preset 클릭 시 UI/log/robot mismatch 방지.
            case alreadyWalking(activePresetLabel: String, requestedLabel: String)
            /// 고급 모드에서 stability 점수가 critical 인 슬라이더 조합.
            case advancedStabilityCritical
            /// preset.requiresRiskConfirmation true 이지만 사용자 risk 미확인.
            case highRiskNotAcknowledged(presetLabel: String)
            // v1.11.24 audit P1-3 — ROBOTIS onboard 시작 차단 사유.
            case onboardSshNotConnected
            case onboardAutoBrokeringOff
            case onboardAckTimeout
            // v1.11.25 audit-D — thermal cool-down 강제. 60°C 도달 후 50°C 미만까지 재시작 차단.
            case motorTempCoolDownRequired(currentTempC: Double, exitTempC: Double)
            /// **v1.21.1 사이클 66 (코덱스 CRITICAL-1)** — emergency 활성 상태에서 preset
            /// 재시작 차단. 종전 cycle 61 이 `.noConnection` 을 재사용 → 사용자에게 "시뮬 모드"
            /// 로 잘못 노출. 전용 cause 추가 — recovery 명확 안내.
            ///
            /// **v1.21.2 사이클 67 (코덱스 MEDIUM-3 fix)** — `trigger` payload 추가.
            /// 종전: `.emergencyActive` 가 associated value 없음 → 사용자 메시지가 generic
            /// "긴급 정지 상태" → 어떤 trigger (userClick / balanceLostL3 / thermalOverheat
            /// 등) 가 emergency 유발했는지 알 수 없음. payload 가 mental model + telemetry
            /// 정확도 모두 회복.
            case emergencyActive(trigger: EmergencyTrigger)
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
            case .imuUnavailable:
                return "🛑 IMU 응답 없음 — 자세 보정/낙상 감지 chain 불가. 연결/플라이트 확인 후 재시도"
            case .imuStale:
                return "🛑 IMU 지연 5초+ — outdated 데이터로 보정 시 fall 위험. 연결 확인 후 재시도"
            case .imuPlausibilityFailed(let detail):
                return "🛑 IMU plausibility 실패 (\(detail)) — 1g 중력 감지 안 됨. chip 확인 후 재시도"
            case .alreadyWalking(let active, let requested):
                return "⚠️ '\(active)' 진행 중 — '\(requested)' 으로 바꾸려면 먼저 정지(■) 누르세요"
            case .advancedStabilityCritical:
                return "🛑 고급 슬라이더 위험도 critical — 슬라이더 조합 점검 후 재시도"
            case .highRiskNotAcknowledged(let label):
                return "⚠️ '\(label)' 위험 동의 필요 — 위험 시나리오 확인 후 재시도"
            case .onboardSshNotConnected:
                return "🛑 ROBOTIS Onboard 시작 차단 — SSH (RemoteShell) 미연결. 연결 후 재시도"
            case .onboardAutoBrokeringOff:
                return "🛑 ROBOTIS Onboard 시작 차단 — 자동 brokering OFF. 토글을 ON 으로 바꾼 뒤 재시도"
            case .onboardAckTimeout:
                return "🛑 ROBOTIS Onboard ACK 타임아웃 — robot-side demo-pilot patch 미설치/구버전 의심"
            case .motorTempCoolDownRequired(let current, let exit):
                return String(format: "🌡️ 모터 냉각 필요 — 현재 %.1f°C, %.1f°C 미만까지 대기 (60°C 알람 후 cool-down)",
                              current, exit)
            case .emergencyActive(let trigger):
                // **v1.21.2 사이클 67 — 코덱스 MEDIUM-3 fix**: trigger 출처 명시 노출.
                return "🛑 긴급 정지 상태 (\(trigger.koreanLabel)) — recovery (R 키 또는 Recover 버튼) 후 재시작"
            }
        }

        /// 진단/로그용 한 단어 코드. 세션 헤더의 startBlockedReason 에 기록.
        public var diagnosticCode: String {
            switch cause {
            case .noConnection:                                 return "noConnection"
            case .cradleNotConfirmed:                           return "cradleNotConfirmed"
            case .dxlPowerFailed:                               return "dxlPowerFailed"
            case .lowerBodyTorqueFailed:                        return "lowerBodyTorqueFailed"
            case .bulkTorqueFailed:                             return "bulkTorqueFailed"
            case .balanceCorrectorRequiredForCautionPreset:     return "balanceCorrectorRequiredForCautionPreset"
            case .imuUnavailable:                               return "imuUnavailable"
            case .imuStale:                                     return "imuStale"
            case .imuPlausibilityFailed:                        return "imuPlausibilityFailed"
            case .alreadyWalking:                               return "alreadyWalking"
            case .advancedStabilityCritical:                    return "advancedStabilityCritical"
            case .highRiskNotAcknowledged:                      return "highRiskNotAcknowledged"
            case .onboardSshNotConnected:                       return "onboardSshNotConnected"
            case .onboardAutoBrokeringOff:                      return "onboardAutoBrokeringOff"
            case .onboardAckTimeout:                            return "onboardAckTimeout"
            case .motorTempCoolDownRequired:                    return "motorTempCoolDownRequired"
            // **v1.21.2 사이클 67 — 코덱스 MEDIUM-3 fix**: trigger 별 telemetry 추적.
            case .emergencyActive(let trigger):                 return "emergencyActive_\(trigger.rawValue)"
            }
        }
    }
}

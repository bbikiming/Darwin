import Foundation

/// Remote Pilot 4-layer 안전 게이트 (PRD §5.4 / §9).
///
/// 단일 정책. 단계별 활성 layer 만 다름:
///   - v1.0: **L0 + L1 + L2** (E-stop / armed / HighRisk-confirm).
///   - v1.1+: L4 (IMU) 추가.
///   - v1.5+: L3 (deadman, Walk only) 추가.
@MainActor
public final class PilotSafetyGate: ObservableObject {
    /// ARM 상태 — drag-to-arm 완료 시 true.
    @Published public private(set) var armed: Bool = false

    /// E-stop 시 빨간 flash 트리거 (0.3 s).
    @Published public private(set) var flashRed: Bool = false

    /// 사용자에게 표시할 마지막 게이트 거부 사유.
    @Published public private(set) var lastBlockReason: String?

    public init() {}

    /// ARM 슬라이더 drag 완료 시 호출 — TeleopChannel.arm 의 종착점.
    public func arm() {
        armed = true
        Harness.shared.record(.pilotSafetyArmed, level: .info, actor: .user)
    }

    /// DISARM (ESC / 사용자 명시 / 연결 끊김 / 비상정지).
    /// - Parameter source: `.user` (사용자 명시) 또는 `.system` (비상정지 등 자동).
    public func disarm(source: TelemetryActor = .user) {
        armed = false
        lastBlockReason = nil
        Harness.shared.record(.pilotSafetyDisarmed, level: .info, actor: source)
    }

    /// E-stop 시각 시그널 — 0.3 s 후 자동 해제.
    public func triggerFlashRed() {
        flashRed = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            flashRed = false
        }
    }

    /// 한 모션 실행 허용 여부 (L1 + L2).
    /// L0 (E-stop) 은 별도 단축키 핸들러가 무조건 적용 — 게이트 미사용.
    public enum GateResult: Equatable {
        case allow
        case blockUnarmed
        case requireHighRiskConfirm

        public var message: String? {
            switch self {
            case .allow:                  return nil
            case .blockUnarmed:           return "ARM 슬라이더를 먼저 잠금 해제하세요"
            case .requireHighRiskConfirm: return "위험 동작 — 확인이 필요합니다"
            }
        }
    }

    /// 한 모션 송출 전 게이트 체크.
    /// - Parameters:
    ///   - meta: 송출할 motion 의 메타데이터.
    ///   - confirmRisk: 사용자가 위험 확인 다이얼로그를 통과했는가.
    public func allowMotion(_ meta: MotionPageMetadata, confirmRisk: Bool) -> GateResult {
        if !armed {
            lastBlockReason = GateResult.blockUnarmed.message
            Harness.shared.record(
                .pilotSafetyGateBlocked, level: .warn, actor: .system,
                data: ["reason": AnyCodable("blockUnarmed"),
                       "motion_name": AnyCodable(Harness.shortHash(meta.displayName))]
            )
            return .blockUnarmed
        }
        if meta.safetyClass == .highRisk && !confirmRisk {
            lastBlockReason = GateResult.requireHighRiskConfirm.message
            Harness.shared.record(
                .pilotSafetyGateBlocked, level: .warn, actor: .system,
                data: ["reason": AnyCodable("requireHighRiskConfirm"),
                       "motion_name": AnyCodable(Harness.shortHash(meta.displayName))]
            )
            return .requireHighRiskConfirm
        }
        lastBlockReason = nil
        return .allow
    }
}

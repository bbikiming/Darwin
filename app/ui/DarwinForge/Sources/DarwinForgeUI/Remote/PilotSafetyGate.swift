import ForgeCore
import SwiftUI

/// 안전 게이트 결과.
public enum GateResult {
    case allow
    case block(reason: String)
    case requireConfirm(title: String, message: String)
}

/// Remote Pilot 안전 게이트 — L1(ARM) + L2(HighRisk confirm).
/// PRD §5.1 4계층 안전 게이트.
@MainActor
public final class PilotSafetyGate: ObservableObject {
    @Published public var armed: Bool = false
    @Published public var flashRed: Bool = false  // E-stop 시 0.3s flash

    public init() {}

    /// 모션 송출 허용 여부 결정.
    public func allowMotion(_ meta: MotionPageMetadata, confirmRisk: Bool) -> GateResult {
        if !armed {
            return .block(reason: "ARM 먼저 — 슬라이더를 오른쪽으로 드래그하세요")
        }
        if meta.safetyClass == .highRisk && !confirmRisk {
            return .requireConfirm(
                title: "위험 동작 확인",
                message: "\(meta.displayNameKo)은 단발 지지 동작입니다. 로봇을 크래들에 거치하고 주변을 정리하세요.\n\n계속하시겠습니까?"
            )
        }
        return .allow
    }

    /// E-stop: 0.3s 빨간 flash.
    public func triggerEstopFlash() {
        flashRed = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            flashRed = false
        }
    }
}

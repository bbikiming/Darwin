import Foundation

/// **v1.17.0 (2026-05-21) Phase 4 — 통합 input layer**.
///
/// keyboard / Tello / 미래 게임패드 / DJI RC 모든 입력을 동일한 `PilotIntent` 로 정규화.
/// 다운스트림 `WalkLabRCBridge` 는 source 무관하게 단일 의도로만 처리 → 안전 검증 일관성.
///
/// # 비유
///
/// 음성 인식 시스템 — 마이크/iOS 키보드/한국어 IME 어느 입력이든 같은 텍스트 string 으로
/// 변환한 후에야 모델 처리. 본 layer 도 같은 원리 — 입력 종류 ≠ 의미, 의도는 동일 형식.
///
/// # 4 kind
///
/// - `.move(WalkingCommand)` — stick 매핑 결과 (Tello/keyboard 어느 쪽이든)
/// - `.stop` — 안전 정지 (사용자 명시 또는 deadzone 진입)
/// - `.emergency` — 긴급 정지 (모터 OFF, Mac/펌웨어 모두 즉시)
/// - `.motion(String)` — 미래: motion catalog id (예: `"wave_hand"`) — Phase 5
public struct PilotIntent: Equatable, Sendable, Hashable {
    public enum Kind: Equatable, Sendable, Hashable {
        case move(WalkingCommand)
        case stop
        case emergency
        case motion(String)
    }

    public let kind: Kind
    public let source: InputSource
    /// 입력 발생 시각 — telemetry / debug 용. 기본 now().
    public let timestamp: Date

    public init(kind: Kind, source: InputSource, timestamp: Date = Date()) {
        self.kind = kind
        self.source = source
        self.timestamp = timestamp
    }

    // MARK: - Convenience

    public static func move(_ cmd: WalkingCommand, from source: InputSource) -> PilotIntent {
        PilotIntent(kind: .move(cmd), source: source)
    }

    public static func stop(from source: InputSource) -> PilotIntent {
        PilotIntent(kind: .stop, source: source)
    }

    public static func emergency(from source: InputSource) -> PilotIntent {
        PilotIntent(kind: .emergency, source: source)
    }
}

// MARK: - Input source

/// 입력 출처 — telemetry / safety policy 별 분류.
public enum InputSource: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// WASD / QE / Space 등 macOS 키보드.
    case keyboard
    /// DJI Tello drone (또는 mock) — UDP 8889.
    case tello
    /// macOS GameController.framework (Xbox/PS 게임패드, 미래).
    case gamepad
    /// DJI 정식 RC (iOS bridge 또는 USB HID, 미래).
    case djiRC
    /// SwiftUI 버튼 클릭 (PresetButton / PilotHud emergency 버튼 등).
    case ui

    public var label: String {
        switch self {
        case .keyboard:  return "키보드"
        case .tello:     return "Tello"
        case .gamepad:   return "게임패드"
        case .djiRC:     return "DJI RC"
        case .ui:        return "UI 버튼"
        }
    }

    public var icon: String {
        switch self {
        case .keyboard:  return "keyboard"
        case .tello:     return "airplane.circle"
        case .gamepad:   return "gamecontroller"
        case .djiRC:     return "antenna.radiowaves.left.and.right"
        case .ui:        return "hand.tap"
        }
    }
}

// MARK: - Pilot input summary (WalkTrialStore 연계)

/// **Phase 4 — P4-C**: trial 동안 누적된 pilot input 통계.
///
/// `WalkTrial.config` 에 optional 로 첨부 → Recommender 가 "사용자가 선호한 amplitude
/// 분포" 학습 신호로 사용. 예: 사용자가 매번 stride 보다 turn 위주로 조종 → 다음 추천에서
/// `turnDeg` 우선 최적화.
public struct PilotInputSummary: Codable, Sendable, Equatable {
    /// 본 trial 에서 사용된 모든 input source (중복 제거).
    public let sourcesUsed: [InputSource]
    /// 총 stick event 수 (move intent + stop intent).
    public let totalEvents: Int
    /// move intent 의 strideMm 평균 (절대값) — 사용자 의도 amplitude.
    public let avgAbsStrideMm: Double
    /// 평균 sideMm (절댓값).
    public let avgAbsSideMm: Double
    /// 평균 turnDeg (절댓값).
    public let avgAbsTurnDeg: Double
    /// peak strideMm (양수만, 사용자가 어느 정도 까지 가속).
    public let peakStrideMm: Double
    public let peakSideMm: Double
    public let peakTurnDeg: Double
    /// emergency intent 가 발생했는가 (1회라도) — 사용자가 비상 정지를 발화한 trial.
    public let emergencyTriggered: Bool

    public init(
        sourcesUsed: [InputSource],
        totalEvents: Int,
        avgAbsStrideMm: Double,
        avgAbsSideMm: Double,
        avgAbsTurnDeg: Double,
        peakStrideMm: Double,
        peakSideMm: Double,
        peakTurnDeg: Double,
        emergencyTriggered: Bool
    ) {
        self.sourcesUsed = sourcesUsed
        self.totalEvents = totalEvents
        self.avgAbsStrideMm = avgAbsStrideMm
        self.avgAbsSideMm = avgAbsSideMm
        self.avgAbsTurnDeg = avgAbsTurnDeg
        self.peakStrideMm = peakStrideMm
        self.peakSideMm = peakSideMm
        self.peakTurnDeg = peakTurnDeg
        self.emergencyTriggered = emergencyTriggered
    }

    /// pilot input 없음 — 사용자가 UI preset 만 사용한 trial.
    public static let empty = PilotInputSummary(
        sourcesUsed: [], totalEvents: 0,
        avgAbsStrideMm: 0, avgAbsSideMm: 0, avgAbsTurnDeg: 0,
        peakStrideMm: 0, peakSideMm: 0, peakTurnDeg: 0,
        emergencyTriggered: false
    )

    public var hasData: Bool { totalEvents > 0 }
}

// MARK: - Pilot input accumulator (Phase 4 — bridge 내부)

/// trial 진행 중 PilotIntent 를 누적 → 종료 시 `PilotInputSummary` 산출.
/// thread-safety: `@MainActor` 전제 — WalkLabRCBridge 에서만 호출.
public final class PilotInputAccumulator {
    private var sources: Set<InputSource> = []
    private var totalEvents: Int = 0
    private var sumAbsStride: Double = 0
    private var sumAbsSide: Double = 0
    private var sumAbsTurn: Double = 0
    private var peakStride: Double = 0
    private var peakSide: Double = 0
    private var peakTurn: Double = 0
    private var moveCount: Int = 0
    private var emergencyTriggered: Bool = false

    public init() {}

    public func record(_ intent: PilotIntent) {
        sources.insert(intent.source)
        totalEvents += 1
        switch intent.kind {
        case .move(let cmd):
            moveCount += 1
            sumAbsStride += abs(cmd.strideMm)
            sumAbsSide += abs(cmd.sideMm)
            sumAbsTurn += abs(cmd.turnDeg)
            if cmd.strideMm > peakStride { peakStride = cmd.strideMm }
            if cmd.sideMm > peakSide { peakSide = cmd.sideMm }
            if cmd.turnDeg > peakTurn { peakTurn = cmd.turnDeg }
        case .emergency:
            emergencyTriggered = true
        case .stop, .motion:
            break
        }
    }

    public func reset() {
        sources.removeAll()
        totalEvents = 0
        sumAbsStride = 0; sumAbsSide = 0; sumAbsTurn = 0
        peakStride = 0; peakSide = 0; peakTurn = 0
        moveCount = 0
        emergencyTriggered = false
    }

    public func summarize() -> PilotInputSummary {
        let n = max(1, moveCount)
        return PilotInputSummary(
            sourcesUsed: Array(sources).sorted { $0.rawValue < $1.rawValue },
            totalEvents: totalEvents,
            avgAbsStrideMm: sumAbsStride / Double(n),
            avgAbsSideMm: sumAbsSide / Double(n),
            avgAbsTurnDeg: sumAbsTurn / Double(n),
            peakStrideMm: peakStride,
            peakSideMm: peakSide,
            peakTurnDeg: peakTurn,
            emergencyTriggered: emergencyTriggered
        )
    }
}

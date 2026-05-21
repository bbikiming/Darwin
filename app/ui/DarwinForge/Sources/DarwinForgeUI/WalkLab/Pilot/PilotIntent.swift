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
    /// 총 stick event 수 (move + stop + emergency + motion).
    public let totalEvents: Int
    /// **v1.20.10 사이클 16-fix HIGH 1 (코덱스)** — move intent 만 별도 카운트.
    /// Recommender 가 "실제 조종 강도" 신호로 사용. stop/emergency/motion 분리.
    public let moveEventCount: Int
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
    /// **v1.20.10 사이클 16-fix HIGH 2 (코덱스)** — 음수 방향 peak (절댓값).
    /// 왼쪽 strafe / 시계 회전 / 후진을 캡쳐. 종전: peak* 가 양수만 → 후진 입력은 0 으로 유지.
    public let peakNegStrideMm: Double
    public let peakNegSideMm: Double
    public let peakNegTurnDeg: Double
    /// emergency intent 가 발생했는가 (1회라도) — 사용자가 비상 정지를 발화한 trial.
    public let emergencyTriggered: Bool
    /// **v1.20.16 사이클 22** — handlePreset 호출 횟수.
    /// 사용자가 trial 중 preset 단축키 (0-7) 로 전환한 횟수. 높을수록 "사용자가 적극 조작" 신호.
    public let presetChangeCount: Int

    // **v1.20.17.1 사이클 23-fix HIGH (코덱스)** — synthesized Codable 이 default 값을
    // missing key 에 적용 안 함. 기존 JSON (presetChangeCount, moveEventCount, peakNeg* 미포함)
    // 디코딩 시 실패 → 전체 trial nil 처리. custom init(from:) 으로 backward-compat.
    enum CodingKeys: String, CodingKey {
        case sourcesUsed, totalEvents, moveEventCount,
             avgAbsStrideMm, avgAbsSideMm, avgAbsTurnDeg,
             peakStrideMm, peakSideMm, peakTurnDeg,
             peakNegStrideMm, peakNegSideMm, peakNegTurnDeg,
             emergencyTriggered, presetChangeCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourcesUsed = try c.decode([InputSource].self, forKey: .sourcesUsed)
        totalEvents = try c.decode(Int.self, forKey: .totalEvents)
        moveEventCount = try c.decodeIfPresent(Int.self, forKey: .moveEventCount) ?? 0
        avgAbsStrideMm = try c.decode(Double.self, forKey: .avgAbsStrideMm)
        avgAbsSideMm = try c.decode(Double.self, forKey: .avgAbsSideMm)
        avgAbsTurnDeg = try c.decode(Double.self, forKey: .avgAbsTurnDeg)
        peakStrideMm = try c.decode(Double.self, forKey: .peakStrideMm)
        peakSideMm = try c.decode(Double.self, forKey: .peakSideMm)
        peakTurnDeg = try c.decode(Double.self, forKey: .peakTurnDeg)
        peakNegStrideMm = try c.decodeIfPresent(Double.self, forKey: .peakNegStrideMm) ?? 0
        peakNegSideMm = try c.decodeIfPresent(Double.self, forKey: .peakNegSideMm) ?? 0
        peakNegTurnDeg = try c.decodeIfPresent(Double.self, forKey: .peakNegTurnDeg) ?? 0
        emergencyTriggered = try c.decode(Bool.self, forKey: .emergencyTriggered)
        presetChangeCount = try c.decodeIfPresent(Int.self, forKey: .presetChangeCount) ?? 0
    }

    public init(
        sourcesUsed: [InputSource],
        totalEvents: Int,
        moveEventCount: Int = 0,
        avgAbsStrideMm: Double,
        avgAbsSideMm: Double,
        avgAbsTurnDeg: Double,
        peakStrideMm: Double,
        peakSideMm: Double,
        peakTurnDeg: Double,
        peakNegStrideMm: Double = 0,
        peakNegSideMm: Double = 0,
        peakNegTurnDeg: Double = 0,
        emergencyTriggered: Bool,
        presetChangeCount: Int = 0
    ) {
        self.sourcesUsed = sourcesUsed
        self.totalEvents = totalEvents
        self.moveEventCount = moveEventCount
        self.avgAbsStrideMm = avgAbsStrideMm
        self.avgAbsSideMm = avgAbsSideMm
        self.avgAbsTurnDeg = avgAbsTurnDeg
        self.peakStrideMm = peakStrideMm
        self.peakSideMm = peakSideMm
        self.peakTurnDeg = peakTurnDeg
        self.peakNegStrideMm = peakNegStrideMm
        self.peakNegSideMm = peakNegSideMm
        self.peakNegTurnDeg = peakNegTurnDeg
        self.emergencyTriggered = emergencyTriggered
        self.presetChangeCount = presetChangeCount
    }

    /// **v1.20.10 사이클 16-fix HIGH 2 (코덱스)** — 양수/음수 양쪽 합산 max abs.
    /// 추천에 사용: 사용자가 한쪽 방향만 밀어도 max 신뢰 가능.
    public var peakAbsStrideMm: Double { max(peakStrideMm, peakNegStrideMm) }
    public var peakAbsSideMm: Double   { max(peakSideMm,   peakNegSideMm)   }
    public var peakAbsTurnDeg: Double  { max(peakTurnDeg,  peakNegTurnDeg)  }

    /// **v1.20.28 사이클 34** — 단일 "comfort level" 지표 (0..~50).
    /// 3 축 peakAbs 의 정규화된 평균. Recommender / UI 가 한 숫자로 trial 비교 가능.
    /// 0 = pilot 미사용, 높을수록 사용자가 큰 amplitude 사용.
    /// 정규화 기준: stride 40mm = 1.0, side 25mm = 1.0, turn 20° = 1.0 (TelloRCMapper clamp).
    public var comfortLevel: Double {
        let normStride = peakAbsStrideMm / 40.0
        let normSide   = peakAbsSideMm / 25.0
        let normTurn   = peakAbsTurnDeg / 20.0
        return (normStride + normSide + normTurn) / 3.0
    }

    /// pilot input 없음 — 사용자가 UI preset 만 사용한 trial.
    public static let empty = PilotInputSummary(
        sourcesUsed: [], totalEvents: 0, moveEventCount: 0,
        avgAbsStrideMm: 0, avgAbsSideMm: 0, avgAbsTurnDeg: 0,
        peakStrideMm: 0, peakSideMm: 0, peakTurnDeg: 0,
        peakNegStrideMm: 0, peakNegSideMm: 0, peakNegTurnDeg: 0,
        emergencyTriggered: false,
        presetChangeCount: 0
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
    /// **v1.20.10 사이클 16-fix HIGH 2 (코덱스)** — 음수 방향 peak (값은 양수로 저장 — abs).
    private var peakNegStride: Double = 0
    private var peakNegSide: Double = 0
    private var peakNegTurn: Double = 0
    private var moveCount: Int = 0
    private var emergencyTriggered: Bool = false
    /// **v1.20.16 사이클 22** — handlePreset 호출 횟수.
    private var presetChangeCount: Int = 0
    /// **v1.20.7 사이클 13** — live event rate 계산용 ring buffer (최근 N event 타임스탬프).
    /// 메모리 제한: 최대 64 entry. 더 오래된 건 drop.
    private var recentTimestamps: [Date] = []
    private let recentTimestampsCapacity: Int = 64

    public init() {}

    public func record(_ intent: PilotIntent) {
        sources.insert(intent.source)
        totalEvents += 1
        recentTimestamps.append(intent.timestamp)
        if recentTimestamps.count > recentTimestampsCapacity {
            recentTimestamps.removeFirst(recentTimestamps.count - recentTimestampsCapacity)
        }
        switch intent.kind {
        case .move(let cmd):
            moveCount += 1
            sumAbsStride += abs(cmd.strideMm)
            sumAbsSide += abs(cmd.sideMm)
            sumAbsTurn += abs(cmd.turnDeg)
            // **v1.20.10 사이클 16-fix HIGH 2 (코덱스)** — 양수/음수 양쪽 peak 추적.
            if cmd.strideMm > peakStride { peakStride = cmd.strideMm }
            if cmd.sideMm   > peakSide   { peakSide   = cmd.sideMm   }
            if cmd.turnDeg  > peakTurn   { peakTurn   = cmd.turnDeg  }
            if -cmd.strideMm > peakNegStride { peakNegStride = -cmd.strideMm }
            if -cmd.sideMm   > peakNegSide   { peakNegSide   = -cmd.sideMm   }
            if -cmd.turnDeg  > peakNegTurn   { peakNegTurn   = -cmd.turnDeg  }
        case .emergency:
            emergencyTriggered = true
        case .stop, .motion:
            break
        }
    }

    /// **v1.20.16 사이클 22** — preset 단축키 (0-7) 호출 발화.
    /// totalEvents 와 별도 — preset 전환은 stop/move/emergency 와 다른 의도.
    public func recordPresetChange(source: InputSource) {
        sources.insert(source)
        presetChangeCount += 1
    }

    public func reset() {
        sources.removeAll()
        totalEvents = 0
        sumAbsStride = 0; sumAbsSide = 0; sumAbsTurn = 0
        peakStride = 0; peakSide = 0; peakTurn = 0
        peakNegStride = 0; peakNegSide = 0; peakNegTurn = 0
        moveCount = 0
        emergencyTriggered = false
        presetChangeCount = 0
        recentTimestamps.removeAll()
    }

    /// **v1.20.7 사이클 13** — 마지막 `window` 초 동안의 event rate (events / sec).
    /// `now` 기준 — caller 가 명시 (테스트 deterministic). 기본 Date().
    /// window=1.0 일 때: 최근 1초 안의 event 개수 = 즉시 활동 강도.
    public func eventsPerSecond(window: TimeInterval = 1.0, now: Date = Date()) -> Double {
        guard window > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-window)
        let recentCount = recentTimestamps.filter { $0 >= cutoff }.count
        return Double(recentCount) / window
    }

    public func summarize() -> PilotInputSummary {
        let n = max(1, moveCount)
        return PilotInputSummary(
            sourcesUsed: Array(sources).sorted { $0.rawValue < $1.rawValue },
            totalEvents: totalEvents,
            moveEventCount: moveCount,
            avgAbsStrideMm: sumAbsStride / Double(n),
            avgAbsSideMm: sumAbsSide / Double(n),
            avgAbsTurnDeg: sumAbsTurn / Double(n),
            peakStrideMm: peakStride,
            peakSideMm: peakSide,
            peakTurnDeg: peakTurn,
            peakNegStrideMm: peakNegStride,
            peakNegSideMm: peakNegSide,
            peakNegTurnDeg: peakNegTurn,
            emergencyTriggered: emergencyTriggered,
            presetChangeCount: presetChangeCount
        )
    }
}

import Foundation

/// B2 — relay walk conflation slot: a **two-lane drain buffer** (cockpit-latency-hardening).
///
/// 비유: 우체통 두 개. 하나는 "최신 속도" 칸 — 새 편지가 오면 이전 편지를 갈아 끼운다
/// (latest-wins). 다른 하나는 "긴급" 칸 — 들어온 순서대로 차곡차곡 쌓이고 절대 버리지
/// 않는다(STOP/E-STOP/disable). 집배원(drain)은 긴급 칸을 **먼저** 순서대로 비우고,
/// 그 다음 최신 속도 한 통을 가져간다. → **안전 프레임은 늦은 walk 보다 항상 앞서고
/// 절대 누락되지 않는다**. 이게 이 타입의 살아있는(항상 유효한) 안전 속성이다.
///
/// **coalescing 의 현실(SDD bounce HIGH)**: 실제 conflation(여러 moving 프레임을 한
/// 장으로 합침)은 슬롯에 두 장 이상이 쌓일 때만 일어난다. 그러나 현 production 경로는
/// MobileRelayServer(actor) 가 프레임마다 await 하고 transport(WSChannel.taskChain)도
/// 프레임을 직렬 전달하므로, `handleWalk` 는 매번 한 장 offer → 즉시 drain 한다 →
/// **coalescing 은 현 모델에서 no-op**(supersededWalkFrames 는 사실상 0). 이 타입은
/// 미래에 ingest/drain 을 분리해 합칠 수 있도록 conflation-ready 로 설계됐지만, 지금
/// 켜져 있는 가치는 "두 레인 분리 + 순서 보장"이다. 합쳐진다고 주장하지 않는다.
///
/// 불변성: 모든 변형은 새 값을 반환한다(in-place mutation 없음). 단일 writer 가
/// `offering(_:)` 로 누적하고, drain 시점에 한 번 `draining()` 으로 소비한다.
public struct WalkConflationSlot: Sendable, Equatable {

    /// 슬롯에 들어가는 한 프레임. moving 속도는 `.walk`, 안전(stop/disable/estop)은
    /// `.safety`. 분류는 서버(`handleWalk`)가 enabled/preset 으로 결정한다.
    public enum Frame: Sendable, Equatable {
        /// MOVING walk velocity — latest-wins 대상.
        case walk(WalkPayload)
        /// 안전 프레임(STOP / enabled=false / E-STOP) — never-drop·ordered.
        case safety(WalkPayload)
    }

    /// 합쳐진 최신 moving 프레임(없으면 nil).
    private let pendingWalk: WalkPayload?
    /// 들어온 순서를 보존하는 안전 프레임 큐.
    private let safetyQueue: [WalkPayload]
    /// 이번 누적 구간에서 최신 walk 에 밀려난(superseded) moving 프레임 수.
    /// drain 시 호출자에게 audit 신호로 반환된다.
    private let supersededWalkFrames: Int

    public init() {
        self.init(pendingWalk: nil, safetyQueue: [], supersededWalkFrames: 0)
    }

    private init(pendingWalk: WalkPayload?,
                 safetyQueue: [WalkPayload],
                 supersededWalkFrames: Int) {
        self.pendingWalk = pendingWalk
        self.safetyQueue = safetyQueue
        self.supersededWalkFrames = supersededWalkFrames
    }

    /// 프레임 한 장을 누적한 **새 슬롯**을 반환한다(원본 불변).
    ///
    /// - `.walk`: pending 을 교체(latest-wins). 직전에 pending 이 있었다면
    ///   superseded 카운트 +1 (버려진 게 아니라 "밀려났음"을 기록).
    /// - `.safety`: 큐에 순서대로 append. 절대 합치거나 재정렬하지 않는다.
    public func offering(_ frame: Frame) -> WalkConflationSlot {
        switch frame {
        case .walk(let payload):
            let superseded = pendingWalk == nil
                ? supersededWalkFrames
                : supersededWalkFrames + 1
            return WalkConflationSlot(pendingWalk: payload,
                                      safetyQueue: safetyQueue,
                                      supersededWalkFrames: superseded)
        case .safety(let payload):
            return WalkConflationSlot(pendingWalk: pendingWalk,
                                      safetyQueue: safetyQueue + [payload],
                                      supersededWalkFrames: supersededWalkFrames)
        }
    }

    /// 호출자가 송출할 프레임 목록과, 밀려난 moving 프레임 수를 반환하며 **슬롯을 비운다**.
    ///
    /// 순서 보장: **안전 프레임이 먼저**(들어온 순서대로), 그 다음 최신 moving 한 장.
    /// 이로써 [walk, walk, STOP, walk] → STOP 이 늦은 walk 보다 항상 앞선다.
    ///
    /// `mutating` 이지만 reference-aliasing mutation 이 아니라 value-type **consume**
    /// 이다(self 를 빈 값으로 교체). drain 은 정확히 한 번 소비돼야 하므로(중복 송출
    /// 방지) 이 소비 시맨틱이 안전 계약의 일부다. 비유: 우체통을 비우면 칸이 빈다.
    public mutating func draining() -> (frames: [Frame], droppedWalkFrames: Int) {
        var out: [Frame] = safetyQueue.map { .safety($0) }
        if let walk = pendingWalk {
            out.append(.walk(walk))
        }
        let dropped = supersededWalkFrames
        self = WalkConflationSlot()
        return (out, dropped)
    }
}

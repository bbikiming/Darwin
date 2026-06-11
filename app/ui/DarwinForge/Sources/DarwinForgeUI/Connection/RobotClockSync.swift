import Foundation
import os

/// 로봇 클럭 ↔ Mac 클럭 오프셋 추정기 (walklab-onboard-teleop-upgrade Wave O0-1).
///
/// 비유: 멀리 있는 친구와 통화하며 "지금 몇 시야?"를 주고받아, 친구 시계가 내 시계보다
/// 얼마나 빠른지/느린지(오프셋)를 매번 조금씩 보정해 평균낸다. 그러면 친구가 "3시에 했어"
/// 라고 말한 사건이 *내 시계로* 언제였는지 환산할 수 있다.
///
/// 동작: 명령 ACK 에는 이미 로봇 `ts_ms` 가 실려온다(`OK {ts} {cmd_id}`,
/// `RobotSetupCommand.walkLabRobotisSendCommand`). 명령 송신 시각 `t_tx` 와 ACK 수신 시각
/// `t_rx` 를 알면, 대칭 RTT 가정 하에
/// ```
/// offset ≈ ts_robot − (t_tx + t_rx) / 2
/// ```
/// 가 로봇시각−Mac시각이다(NTP 의 단순화). 한 표본은 네트워크 지터로 출렁이므로 EWMA 로
/// 평활한다. 이 오프셋으로 텔레메트리/ACK 의 로봇 ts 를 Mac epoch 로 환산해
/// `PilotLatencyTracer.ackReceived` 의 "로봇 적용 시각" 마크를 채운다(E2E 레이턴시 완성).
///
/// 동시성: 명령 채널/폴러(여러 큐)에서 `record`, MainActor HUD 에서 `offsetMs` 읽기.
/// `OSAllocatedUnfairLock` 으로 보호 — 진입은 수십 ns, 할당 없음.
public final class RobotClockSync: Sendable {
    /// 프로세스 공유 인스턴스 — 채널이 기록하고 tracer/HUD 가 읽는다.
    public static let shared = RobotClockSync()

    /// 한 RTT 표본.
    public struct Sample: Sendable, Equatable {
        public let robotTsMs: Int64
        public let txMs: Int64
        public let rxMs: Int64
        public init(robotTsMs: Int64, txMs: Int64, rxMs: Int64) {
            self.robotTsMs = robotTsMs
            self.txMs = txMs
            self.rxMs = rxMs
        }
        /// 이 표본의 순간 오프셋(로봇 − Mac, ms). 대칭 RTT 가정.
        public var instantOffsetMs: Double {
            Double(robotTsMs) - (Double(txMs) + Double(rxMs)) / 2.0
        }
        /// 이 표본의 왕복 시간(ms). 음수면 클럭 역전/측정 오류 → 거부 대상.
        public var rttMs: Int64 { rxMs - txMs }
    }

    private struct State {
        var offsetMs: Double?     // nil = 표본 0
        var sampleCount: Int
        var lastRttMs: Int64
    }

    private let state: OSAllocatedUnfairLock<State>
    /// EWMA 가중치 — 클수록 최신 표본에 민감. 0.2 = 보수적 평활(네트워크 지터 흡수).
    private let alpha: Double
    /// 비정상 RTT 상한(ms). 이보다 큰 표본은 오프셋 추정에서 제외(stall 오염 방지).
    private let maxAcceptableRttMs: Int64

    public init(alpha: Double = 0.2, maxAcceptableRttMs: Int64 = 2000) {
        self.alpha = max(0.01, min(1.0, alpha))
        self.maxAcceptableRttMs = maxAcceptableRttMs
        state = OSAllocatedUnfairLock(initialState: State(offsetMs: nil, sampleCount: 0, lastRttMs: 0))
    }

    /// RTT 표본 1건으로 오프셋 EWMA 갱신. 비정상 표본(음수/과대 RTT)은 무시(반환 false).
    /// 첫 유효 표본은 EWMA 시드(=순간 오프셋)로 채택.
    @discardableResult
    public func record(_ sample: Sample) -> Bool {
        guard sample.rttMs >= 0, sample.rttMs <= maxAcceptableRttMs else { return false }
        let instant = sample.instantOffsetMs
        return state.withLock { s in
            if let prev = s.offsetMs {
                s.offsetMs = prev + alpha * (instant - prev)
            } else {
                s.offsetMs = instant
            }
            s.sampleCount += 1
            s.lastRttMs = sample.rttMs
            return true
        }
    }

    /// 편의: 원시 값으로 표본 기록.
    @discardableResult
    public func record(robotTsMs: Int64, txMs: Int64, rxMs: Int64) -> Bool {
        record(Sample(robotTsMs: robotTsMs, txMs: txMs, rxMs: rxMs))
    }

    /// 현재 오프셋 추정(로봇 − Mac, ms). 표본이 없으면 nil.
    public var offsetMs: Double? { state.withLock { $0.offsetMs } }

    /// 채택된 표본 수.
    public var sampleCount: Int { state.withLock { $0.sampleCount } }

    /// 로봇 ts(ms) → Mac epoch ms 로 환산. 오프셋 미확정이면 nil(추정 불가 — 거짓 마크 금지).
    public func robotToMacMs(_ robotTsMs: Int64) -> Double? {
        guard let off = offsetMs else { return nil }
        return Double(robotTsMs) - off
    }

    public func reset() {
        state.withLock { $0 = State(offsetMs: nil, sampleCount: 0, lastRttMs: 0) }
    }
}
